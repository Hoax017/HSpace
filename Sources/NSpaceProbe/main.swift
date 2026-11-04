import Foundation
import CoreGraphics
import NSpaceContracts
import NSpaceKernel
import DirectoryReader
import Transfer
import DirectoryWatch
import FolderSize
import IconThumb
import ArchiveEngine

// CLI-first probe: drives each pod node directly, bypassing UI orchestration (L-readonly / L-irreversible).
// Not in the .app, not in the production binary. Each pod integrated adds one subcommand.

let args = Array(CommandLine.arguments.dropFirst())

func usage() -> Never {
    print("""
    nspace-probe — NSpace pod node live probe
    Usage:
      nspace-probe list <dir> [--hidden] [--sort name|dateModified|size|kind] [--desc]   # L-readonly: DirectoryReader
      nspace-probe copy <source…> <dest-dir> [--move] [--on-conflict skip|replace|keepBoth|merge]  # L-irreversible: Transfer (full kernel chain)
      nspace-probe watch <dir>                    # L-readonly: DirectoryWatch (prints signals, exits after 10 seconds)
      nspace-probe size <dir>                     # L-readonly: FolderSize (recursive size + elapsed time)
      nspace-probe thumb <file> [--size 128]       # L-readonly: IconThumb (thumbnail pixel dimensions)
      nspace-probe compress <source…> [--format zip|tar.gz] [--into <dir>]   # L-irreversible: ArchiveEngine (full kernel chain)
      nspace-probe extract <archive…> [--into <dir>] [--no-wrapper]        # L-irreversible: ArchiveEngine
    """)
    exit(2)
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

guard let command = args.first else { usage() }
let rest = Array(args.dropFirst())

switch command {
case "list":
    await runList(rest)
case "copy":
    await runCopy(rest)
case "watch":
    await runWatch(rest)
case "size":
    await runSize(rest)
case "thumb":
    await runThumb(rest)
case "compress":
    await runCompress(rest)
case "extract":
    await runExtract(rest)
default:
    FileHandle.standardError.write("Unknown subcommand:\(command)\n".data(using: .utf8)!)
    usage()
}

// MARK: - list (live read-only: real file system)

func runList(_ args: [String]) async {
    var dir: URL?
    var hidden = false
    var sort = SortSpec()
    var i = 0
    while i < args.count {
        switch args[i] {
        case "--hidden": hidden = true
        case "--desc": sort.ascending = false
        case "--sort":
            i += 1
            guard i < args.count, let key = SortSpec.Key(rawValue: args[i]) else { fail("--sort values:name|dateModified|size|kind") }
            sort.key = key
        default:
            dir = URL(fileURLWithPath: (args[i] as NSString).expandingTildeInPath)
        }
        i += 1
    }
    guard let dir else { usage() }

    let reader = DirectoryReader()
    do {
        let t0 = Date()
        let snap = try await reader.load(ReadRequest(directory: dir, includeHidden: hidden, sort: sort))
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        for item in snap.items {
            let mark = item.isDirectory ? "d" : "-"
            let size = item.size.map { String($0) } ?? "-"
            print("\(mark) \(size)\t\(item.name)")
        }
        print("-- \(snap.items.count) items, generation=\(snap.generation), took \(ms)ms")
    } catch {
        fail("Read failed:\(error.localizedDescription)")
    }
}

// MARK: - copy (live irreversible: full kernel → node chain, verifies the mechanism is connected)

struct FixedArbiter: ConflictArbiter {
    let decision: ConflictDecision?
    func arbitrate(operation id: UUID, conflicts: [FileConflict]) async -> [URL: ConflictDecision]? {
        guard let decision else { return nil }
        print("\(conflicts.count) conflicts, policy: \(decision)")
        return Dictionary(uniqueKeysWithValues: conflicts.map { ($0.source, decision) })
    }
}

func runCopy(_ args: [String]) async {
    var paths: [URL] = []
    var move = false
    var decision: ConflictDecision? = .keepBoth
    var i = 0
    while i < args.count {
        switch args[i] {
        case "--move": move = true
        case "--on-conflict":
            i += 1
            guard i < args.count else { usage() }
            switch args[i] {
            case "skip": decision = .skip
            case "replace": decision = .replace
            case "keepBoth": decision = .keepBoth
            case "merge": decision = .mergeFolders
            case "cancel": decision = nil
            default: fail("--on-conflict values:skip|replace|keepBoth|merge|cancel")
            }
        default:
            paths.append(URL(fileURLWithPath: (args[i] as NSString).expandingTildeInPath))
        }
        i += 1
    }
    guard paths.count >= 2 else { usage() }
    let dest = paths.removeLast()

    let kernel = OperationKernel()
    await kernel.register(TransferNode(), for: [.copy, .move, .duplicate])
    await kernel.setArbiter(FixedArbiter(decision: decision))

    let spec = OperationSpec(kind: move ? .move : .copy, sources: paths, destination: dest)
    let id = await kernel.submit(spec)

    for await p in await kernel.projections() where p.id == id {
        let pct = p.bytesTotal > 0 ? Int(Double(p.bytesDone) / Double(p.bytesTotal) * 100) : 0
        print("[\(stateName(p.state))] \(p.filesDone)/\(p.filesTotal) files, \(p.bytesDone)/\(p.bytesTotal) bytes (\(pct)%) \(p.currentPath ?? "")")
        if p.state.isTerminal {
            switch p.state {
            case .completed: print("✓ Done"); exit(0)
            case .cancelled: print("Cancelled"); exit(3)
            case let .failed(message, cls): fail("✗ Failed (\(cls)):\(message)")
            default: break
            }
        }
    }
}

func stateName(_ s: RunState) -> String {
    switch s {
    case .pending: "Queued"
    case .scanning: "Scanning"
    case .awaitingConflict: "Awaiting decision"
    case .running: "Transferring"
    case .completed: "Completed"
    case .cancelled: "Cancelled"
    case .failed: "Failed"
    }
}

// MARK: - compress / extract (live irreversible: full kernel → ArchiveEngine chain)

func driveArchive(_ kernel: OperationKernel, _ spec: OperationSpec) async {
    let id = await kernel.submit(spec)
    for await p in await kernel.projections() where p.id == id {
        let pct = p.bytesTotal > 0 ? Int(Double(p.bytesDone) / Double(p.bytesTotal) * 100) : 0
        print("[\(stateName(p.state))] \(p.filesDone)/\(p.filesTotal) files, \(p.bytesDone)/\(p.bytesTotal) bytes (\(pct)%) \(p.currentPath ?? "")")
        guard p.state.isTerminal else { continue }
        switch p.state {
        case .completed:
            if let r = await kernel.receipt(id) {
                for u in r.createdURLs { print("→ \(u.path)") }
            }
            print("✓ Done"); exit(0)
        case .cancelled: print("Cancelled"); exit(3)
        case let .failed(message, cls): fail("✗ Failed (\(cls)):\(message)")
        default: break
        }
    }
}

func runCompress(_ args: [String]) async {
    var sources: [URL] = []
    var format = "zip"
    var into: URL?
    var i = 0
    while i < args.count {
        switch args[i] {
        case "--format":
            i += 1
            guard i < args.count, ["zip", "tar.gz"].contains(args[i]) else { fail("--format values:zip|tar.gz") }
            format = args[i]
        case "--into":
            i += 1
            guard i < args.count else { usage() }
            into = URL(fileURLWithPath: (args[i] as NSString).expandingTildeInPath)
        default:
            sources.append(URL(fileURLWithPath: (args[i] as NSString).expandingTildeInPath))
        }
        i += 1
    }
    guard !sources.isEmpty else { usage() }

    let kernel = OperationKernel()
    await kernel.register(ArchiveEngineNode(), for: [.compress, .extract])
    await driveArchive(kernel, OperationSpec(kind: .compress, sources: sources, destination: into,
                                             archiveOptions: ArchiveOptions(format: format)))
}

func runExtract(_ args: [String]) async {
    var sources: [URL] = []
    var into: URL?
    var wrapper = true
    var i = 0
    while i < args.count {
        switch args[i] {
        case "--into":
            i += 1
            guard i < args.count else { usage() }
            into = URL(fileURLWithPath: (args[i] as NSString).expandingTildeInPath)
        case "--no-wrapper": wrapper = false
        default:
            sources.append(URL(fileURLWithPath: (args[i] as NSString).expandingTildeInPath))
        }
        i += 1
    }
    guard !sources.isEmpty else { usage() }

    let kernel = OperationKernel()
    await kernel.register(ArchiveEngineNode(), for: [.compress, .extract])
    await driveArchive(kernel, OperationSpec(kind: .extract, sources: sources,
                                             archiveOptions: ArchiveOptions(extractInto: into, createWrapper: wrapper)))
}

// MARK: - watch (live read-only: FSEvents watches a real directory, exits after 10 seconds)

func runWatch(_ args: [String]) async {
    guard let first = args.first else { usage() }
    let dir = URL(fileURLWithPath: (first as NSString).expandingTildeInPath)

    let watcher = DirectoryWatch().watch(dir)
    if let err = watcher.startupError {
        fail("Watch failed to start (\(err.errorClass)):\(err.localizedDescription)")
    }
    print("Watching \(dir.path) … (exits after 10 seconds; touch this directory elsewhere to trigger a signal)")

    await withTaskGroup(of: Void.self) { group in
        group.addTask {
            var n = 0
            for await _ in watcher.signals {
                n += 1
                print("· Change signal #\(n)")
            }
        }
        group.addTask {
            try? await Task.sleep(for: .seconds(10))
        }
        // Wrap up when either child task ends first (the 10-second timer)
        await group.next()
        watcher.stop()
        group.cancelAll()
    }
    print("Stopped watching")
}

// MARK: - size (live read-only: FolderSize recursively sums a real directory)

func runSize(_ args: [String]) async {
    guard let first = args.first else { usage() }
    let dir = URL(fileURLWithPath: (first as NSString).expandingTildeInPath)

    do {
        let t0 = Date()
        let bytes = try await FolderSize().size(of: dir)
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        print("\(dir.path)\n  \(bytes) bytes (\(byteString(bytes))), took \(ms)ms")
    } catch {
        fail("Calculation failed:\(error.localizedDescription)")
    }
}

func byteString(_ b: Int64) -> String {
    let f = ByteCountFormatter()
    f.countStyle = .file
    return f.string(fromByteCount: b)
}

// MARK: - thumb (live read-only: IconThumb generates a real file's thumbnail)

func runThumb(_ args: [String]) async {
    var file: URL?
    var size: CGFloat = 128
    var i = 0
    while i < args.count {
        switch args[i] {
        case "--size":
            i += 1
            guard i < args.count, let v = Double(args[i]) else { fail("--size requires a positive number") }
            size = CGFloat(v)
        default:
            file = URL(fileURLWithPath: (args[i] as NSString).expandingTildeInPath)
        }
        i += 1
    }
    guard let file else { usage() }

    let t0 = Date()
    let image = await IconThumb().thumbnail(for: file, size: size)
    let ms = Int(Date().timeIntervalSince(t0) * 1000)
    if let image {
        print("Thumbnail \(image.width)×\(image.height) pixels (requested size=\(Int(size)), scale=2), took \(ms)ms")
    } else {
        fail("No thumbnail (unsupported type / file missing / generation failed), took \(ms)ms")
    }
}
