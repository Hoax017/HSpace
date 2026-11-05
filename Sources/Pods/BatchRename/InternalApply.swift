import Darwin
import Foundation

// Private concern: the all-or-nothing rename engine

struct RenameMove: Hashable {
    let from: URL
    let to: URL
}

private struct Done {
    let from: URL
    let to: URL
}

private func renameExclusive(_ source: URL, to target: URL) -> Int32 {
    if renamex_np(source.path, target.path, UInt32(RENAME_EXCL)) == 0 { return 0 }
    let failure = errno
    guard failure == ENOTSUP || failure == EINVAL else { return failure }
    // File systems without RENAME_EXCL (exFAT, SMB)
    if itemExists(target) { return EEXIST }
    return rename(source.path, target.path) == 0 ? 0 : errno
}

/// Keeps the original name in front, so that a crash between the two phases leaves a file a person can recognize.
private func parkingURL(for source: URL, batch: String, index: Int) -> URL {
    let suffix = ".hspace-rename-\(batch)-\(index)"
    var name = source.lastPathComponent
    while name.utf8.count + suffix.utf8.count > 255 { name.removeLast() }
    return source.deletingLastPathComponent().appendingPathComponent(name + suffix)
}

func performChecked(_ moves: [RenameMove],
                    progress: @Sendable (Int, Int) -> Void) async throws -> RenameJournal {
    guard !moves.isEmpty else { return RenameJournal(entries: []) }
    // The plan may be minutes old, and a journal may be days old
    let recheck = checkedPlan(sources: moves.map(\.from), names: moves.map(\.to.lastPathComponent))
    if let blocked = recheck.rows.first(where: { if case .blocked = $0.status { true } else { false } }) {
        throw BatchRenameError(.external, refusal(for: blocked), path: blocked.source.path)
    }
    try Task.checkCancellation()

    var comparer = NameComparer()
    func slot(_ url: URL) -> NameSlot {
        let folder = url.deletingLastPathComponent()
        return NameSlot(folder: folder, key: comparer.key(url.lastPathComponent, in: folder))
    }
    // A target still held by a source of this batch (a swap, a chain, or the item's own case change) needs two hops.
    // Everything else goes straight in, so that an interruption leaves as few parked names as possible.
    let held = Set(moves.map { slot($0.from) })
    let batch = String(UUID().uuidString.prefix(8))
    var parked: [(move: RenameMove, parking: URL)] = []
    var direct: [RenameMove] = []
    for (index, move) in moves.enumerated() {
        if held.contains(slot(move.to)) {
            parked.append((move, parkingURL(for: move.from, batch: batch, index: index)))
        } else {
            direct.append(move)
        }
    }

    var done: [Done] = []
    var finished = 0
    func hop(_ from: URL, _ to: URL) throws {
        try Task.checkCancellation()
        let failure = renameExclusive(from, to: to)
        guard failure == 0 else {
            throw BatchRenameError(.external, "Could not rename \(from.lastPathComponent): \(String(cString: strerror(failure)))",
                                   path: from.path)
        }
        done.append(Done(from: from, to: to))
    }

    do {
        for item in parked { try hop(item.move.from, item.parking) }
        for move in direct {
            try hop(move.from, move.to)
            finished += 1
            progress(finished, moves.count)
        }
        for item in parked {
            try hop(item.parking, item.move.to)
            finished += 1
            progress(finished, moves.count)
        }
    } catch {
        let stuck = done.reversed().filter { renameExclusive($0.to, to: $0.from) != 0 }
        guard stuck.isEmpty else {
            let names = stuck.map(\.to.lastPathComponent).joined(separator: ", ")
            throw BatchRenameError(.external, "The rename failed and \(stuck.count) items could not be restored: \(names). First failure: \(error.localizedDescription)",
                                   path: stuck[0].to.path)
        }
        throw error
    }
    return RenameJournal(entries: moves.map { RenameJournalEntry(from: $0.from.path, to: $0.to.path) })
}

private func refusal(for row: RenamePlanRow) -> String {
    switch row.status {
    case .blocked(.sourceMissing): return "\(row.source.lastPathComponent) is no longer there, so nothing was renamed."
    case .blocked(.existsOnDisk): return "\(row.newName) already exists, so nothing was renamed."
    case .blocked(.duplicateInBatch): return "Two items would be named \(row.newName), so nothing was renamed."
    default: return "\(row.newName) is not a valid name, so nothing was renamed."
    }
}
