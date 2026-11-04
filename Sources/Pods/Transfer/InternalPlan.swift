import Foundation
import HSpaceContracts

// Private concern: operation plan building + pre-scan + conflict detection and decision application

struct TransferPlan {
    enum Mode { case copy, move }
    struct Entry {
        let source: URL
        /// Full destination path (with final file name; keepBoth/rename decisions may change it)
        var destination: URL
        /// mergeFolders decision flag: merge recursively instead of replacing wholesale
        var merge = false
        /// Replace decision flag: delete the target and write at transfer time (micro-step 3), never during resolution (so batch cancellation cannot lose untransferred targets)
        var replaceExisting = false
    }
    let mode: Mode
    var entries: [Entry]
}

func makePlan(_ spec: OperationSpec) throws -> TransferPlan {
    switch spec.kind {
    case .copy, .move:
        guard let destDir = spec.destination, !spec.sources.isEmpty else {
            throw TransferError(.logic, "copy/move requires sources and a destination")
        }
        let mode: TransferPlan.Mode = spec.kind == .move ? .move : .copy
        return TransferPlan(mode: mode, entries: spec.sources.map {
            .init(source: $0, destination: destDir.appendingPathComponent($0.lastPathComponent))
        })
    case .duplicate:
        guard !spec.sources.isEmpty else { throw TransferError(.logic, "duplicate requires sources") }
        // Duplicate = copy within the same directory, always keepBoth-named, never conflicts
        return TransferPlan(mode: .copy, entries: spec.sources.map { src in
            let dir = src.deletingLastPathComponent()
            return .init(source: src, destination: dir.appendingPathComponent(keepBothName(for: src, in: dir)))
        })
    default:
        throw TransferError(.logic, "TransferNode does not handle\(spec.kind.rawValue)")
    }
}

struct ScanTotals { var files = 0; var bytes: Int64 = 0 }

/// Pre-scan: file count + total bytes (walks directories; progress denominator), keeping per-source subtotals for move fast-path accounting
func preScan(sources: [URL]) throws -> (total: ScanTotals, perSource: [URL: ScanTotals]) {
    let fm = FileManager.default
    var total = ScanTotals()
    var perSource: [URL: ScanTotals] = [:]
    let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey]
    for src in sources {
        guard let rv = try? src.resourceValues(forKeys: keys) else {
            throw TransferError(.external, "Cannot access source:\(src.lastPathComponent)", path: src.path)
        }
        var sub = ScanTotals()
        if rv.isDirectory == true {
            if let walker = fm.enumerator(at: src, includingPropertiesForKeys: Array(keys),
                                          options: [], errorHandler: nil) {
                for case let child as URL in walker {
                    let crv = try? child.resourceValues(forKeys: keys)
                    if crv?.isDirectory != true {
                        sub.files += 1
                        sub.bytes += Int64(crv?.fileSize ?? 0)
                    }
                }
            }
        } else {
            sub.files = 1
            sub.bytes = Int64(rv.fileSize ?? 0)
        }
        perSource[src] = sub
        total.files += sub.files
        total.bytes += sub.bytes
    }
    return (total, perSource)
}

/// Conflict detection → request decisions → apply them; returns the final entries to execute
func resolveConflicts(plan: TransferPlan, context: NodeContext) async throws -> [TransferPlan.Entry] {
    let fm = FileManager.default
    var conflicts: [FileConflict] = []
    for entry in plan.entries where fm.fileExists(atPath: entry.destination.path) {
        var srcDir: ObjCBool = false, dstDir: ObjCBool = false
        _ = fm.fileExists(atPath: entry.source.path, isDirectory: &srcDir)
        _ = fm.fileExists(atPath: entry.destination.path, isDirectory: &dstDir)
        conflicts.append(FileConflict(source: entry.source, existing: entry.destination,
                                      bothDirectories: srcDir.boolValue && dstDir.boolValue))
    }
    // Ask the user only when on-disk conflicts exist; the in-batch name-claim pass below still runs without them (prevents same-named items colliding within a batch)
    var decisions: [URL: ConflictDecision] = [:]
    if !conflicts.isEmpty {
        guard let d = await context.resolveConflicts(conflicts) else {
            throw CancellationError()  // user cancelled the whole operation in the conflict panel
        }
        decisions = d
    }

    var result: [TransferPlan.Entry] = []
    // Target names already claimed in this batch: keepBoth/rename dedup cannot look only at disk (two same-named sources would both compute "a 2" and collide, and a cross-volume move deletes its source, so that is permanent loss);
    // pass-through entries with no disk conflict must also claim their name and auto-rename on a clash (two same-named sources from different directories copied into one empty directory collide the same way).
    var claimed = Set<String>()
    let existsOrClaimed: (URL) -> Bool = { u in
        fm.fileExists(atPath: u.path) || claimed.contains(u.standardizedFileURL.path)
    }
    for entry in plan.entries {
        if fm.fileExists(atPath: entry.destination.path) {
            // Disk conflict: apply the decision (applyDecision dedups via existsOrClaimed)
            if let resolved = try applyDecision(decisions[entry.source] ?? .skip, to: entry, claimed: &claimed) {
                claimed.insert(resolved.destination.standardizedFileURL.path)
                result.append(resolved)
            }
        } else if claimed.contains(entry.destination.standardizedFileURL.path) {
            // No disk conflict but clashes with a name claimed in this batch → non-destructive auto-rename (same as Finder; two entries never land on one target)
            var e = entry
            let dir = e.destination.deletingLastPathComponent()
            e.destination = dir.appendingPathComponent(
                uniqueName(base: e.destination.deletingPathExtension().lastPathComponent,
                           ext: e.destination.pathExtension, in: dir, existsCheck: existsOrClaimed))
            claimed.insert(e.destination.standardizedFileURL.path)
            result.append(e)
        } else {
            claimed.insert(entry.destination.standardizedFileURL.path)
            result.append(entry)
        }
    }
    return result
}

/// Whether two URLs point to the same physical file (inode-level identity): symlink aliases and case variants on case-insensitive volumes
/// both escape lexical path comparison, so use fileResourceIdentifier; if unavailable, fall back to comparing with symlinks resolved.
/// The self-source safety rule must go through here: lexical comparison would let "Replace" on an aliased path delete the source itself (data loss).
func isSameFile(_ a: URL, _ b: URL) -> Bool {
    let key: Set<URLResourceKey> = [.fileResourceIdentifierKey]
    if let ia = try? a.resourceValues(forKeys: key).fileResourceIdentifier,
       let ib = try? b.resourceValues(forKeys: key).fileResourceIdentifier {
        return ia.isEqual(ib)
    }
    // Fallback (identifier unavailable, only on unusual network/FUSE mounts): compare case-insensitively with symlinks resolved.
    // Conservative: on a case-sensitive volume two files differing only in case count as "same", so replace degrades to rename (one extra copy,
    // but the source is never deleted). That is the safe direction, better than lexical comparison missing it on a case-insensitive volume and deleting the source.
    return a.resolvingSymlinksInPath().standardizedFileURL.path
        .compare(b.resolvingSymlinksInPath().standardizedFileURL.path, options: .caseInsensitive) == .orderedSame
}

/// Applies one conflict decision (includes the M27-B self-source safety rule: when destination is the source itself,
/// "Replace"/"Merge" would delete or self-merge the file being copied from → always neutralized to "Keep Both" renaming, the source is never deleted).
/// Returns nil = skip this entry. Replace only sets a flag; the actual target deletion is deferred to transfer time in micro-step 3 (so batch cancellation cannot lose untransferred targets).
private func applyDecision(_ decision: ConflictDecision,
                          to entry: TransferPlan.Entry,
                          claimed: inout Set<String>) throws -> TransferPlan.Entry? {
    var entry = entry
    let dir = entry.destination.deletingLastPathComponent()
    // Self-source check is inode-level (lexical path comparison can be bypassed by symlink/case aliases → source deleted, data lost)
    let isSelf = isSameFile(entry.destination, entry.source)
    // keepBoth/rename dedup also treats names claimed in this batch as existing
    let exists: (URL) -> Bool = { u in
        FileManager.default.fileExists(atPath: u.path) || claimed.contains(u.standardizedFileURL.path)
    }

    switch decision {
    case .skip:
        return nil
    case .keepBoth:
        entry.destination = dir.appendingPathComponent(keepBothName(for: entry.source, in: dir, existsCheck: exists))
        return entry
    case .replace:
        if isSelf {
            // Self-source: replacing would delete the file being copied from → safely degrade to a renamed copy (never delete the source)
            entry.destination = dir.appendingPathComponent(keepBothName(for: entry.source, in: dir, existsCheck: exists))
            return entry
        }
        entry.replaceExisting = true   // target deletion deferred to transfer time (micro-step 3)
        return entry
    case .mergeFolders:
        if isSelf {
            // Self-source directory merge would recurse into itself → safely degrade to a renamed copy
            entry.destination = dir.appendingPathComponent(keepBothName(for: entry.source, in: dir, existsCheck: exists))
            return entry
        }
        entry.merge = true
        return entry
    case .rename(let newName):
        // Take a single file name component from user input (this also strips any directory separators, preventing path escape)
        let comp = URL(fileURLWithPath: newName)
        let base = comp.deletingPathExtension().lastPathComponent
        let ext = comp.pathExtension
        guard !base.isEmpty else {
            // Empty-name fallback: degrade to keepBoth (never use an empty name or overwrite the source)
            entry.destination = dir.appendingPathComponent(keepBothName(for: entry.source, in: dir, existsCheck: exists))
            return entry
        }
        // uniqueName guarantees no overwrite of existing or batch-claimed names and never lands on the source (clashes get " 2"), so the safety rule cannot be bypassed
        entry.destination = dir.appendingPathComponent(uniqueName(base: base, ext: ext, in: dir, existsCheck: exists))
        return entry
    }
}
