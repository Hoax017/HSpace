import Foundation
import HSpaceContracts

/// Reads both folders and says what a sync would do. Writes nothing. Blocking: call it off the main thread.
public enum SyncPlanner {
    /// `progress` gets the number of items looked at so far. Throws `CancellationError` when the task is cancelled.
    public static func plan(left: URL, right: URL, options: SyncOptions,
                            progress: @escaping @Sendable (Int) -> Void = { _ in }) throws -> SyncPlan {
        let left = left.standardizedFileURL, right = right.standardizedFileURL
        try validate(left, right)
        var walk = Walk(left: left, right: right, options: options, progress: progress)
        try walk.compare(folderLeft: left, folderRight: right, relative: "")
        return walk.finished()
    }

    private static func validate(_ left: URL, _ right: URL) throws {
        for root in [left, right] {
            guard let item = Disk.item(at: root.resolvingSymlinksInPath()), item.type == .folder else {
                throw SyncError(.external, "\(root.path) is not an available folder.")
            }
        }
        let a = left.resolvingSymlinksInPath().path, b = right.resolvingSymlinksInPath().path
        guard a != b else { throw SyncError(.logic, "Choose two different folders.") }
        guard !a.hasPrefix(b + "/"), !b.hasPrefix(a + "/") else {
            throw SyncError(.logic, "One folder is inside the other, so a sync would feed on itself.")
        }
    }
}

private struct Walk {
    let left: URL
    let right: URL
    let options: SyncOptions
    let rules: FilterRules
    let progress: @Sendable (Int) -> Void

    var creates: [SyncAction] = []
    var copies: [SyncAction] = []
    var replaces: [SyncAction] = []
    var deletes: [SyncAction] = []
    var skips: [SyncAction] = []
    var identical = 0
    var extrasKept = 0
    var problems: [SyncProblem] = []
    var seen = 0
    /// Items that take part, on each side: what "empties the receiver" is measured against
    var participants = (left: 0, right: 0)

    init(left: URL, right: URL, options: SyncOptions, progress: @escaping @Sendable (Int) -> Void) {
        self.left = left
        self.right = right
        self.options = options
        self.rules = FilterRules(filter: options.filter)
        self.progress = progress
    }

    private enum Side { case left, right }

    private var deletesExtras: Bool { options.deleteExtras && options.direction != .twoWay }

    private func path(_ relative: String, _ name: String) -> String { relative.isEmpty ? name : relative + "/" + name }

    private func receives(_ side: Side) -> Bool {
        switch options.direction {
        case .leftToRight: side == .right
        case .rightToLeft: side == .left
        case .twoWay: true
        }
    }

    private mutating func read(_ folder: URL) -> [DiskItem]? {
        do {
            return try Disk.list(folder)
        } catch {
            if !problems.contains(where: { $0.path == folder.path }) {
                problems.append(SyncProblem(path: folder.path, message: error.localizedDescription))
            }
            return nil
        }
    }

    private mutating func tick() throws {
        try Task.checkCancellation()
        seen += 1
        if seen % 256 == 0 { progress(seen) }
    }

    mutating func compare(folderLeft: URL, folderRight: URL, relative: String) throws {
        guard let lefts = read(folderLeft), let rights = read(folderRight) else { return }
        var unmatched = Dictionary(rights.map { ($0.name.precomposedStringWithCanonicalMapping, $0) }) { first, _ in first }
        var pairs: [(left: DiskItem?, right: DiskItem?)] = []
        var waiting: [DiskItem] = []
        for item in lefts {
            if let match = unmatched.removeValue(forKey: item.name.precomposedStringWithCanonicalMapping) {
                pairs.append((item, match))
            } else {
                waiting.append(item)
            }
        }
        // A name that differs only by case is one item on the usual volume: treated as two, it would be copied and deleted
        for item in waiting {
            let folded = item.name.precomposedStringWithCanonicalMapping.lowercased()
            let candidates = unmatched.filter { $0.key.lowercased() == folded }
            if candidates.count == 1, let key = candidates.keys.first {
                pairs.append((item, unmatched.removeValue(forKey: key)))
            } else {
                pairs.append((item, nil))
            }
        }
        pairs += unmatched.values.map { (nil, $0) }

        for pair in pairs.sorted(by: { ($0.left ?? $0.right)?.name ?? "" < ($1.left ?? $1.right)?.name ?? "" }) {
            try tick()
            guard let name = (pair.left ?? pair.right)?.name else { continue }
            let relativePath = path(relative, name)
            switch (pair.left, pair.right) {
            case let (l?, r?):
                try both(l, r, relativePath: relativePath)
            case let (l?, nil):
                try onlyOn(.left, l, otherFolder: folderRight, relativePath: relativePath)
            case let (nil, r?):
                try onlyOn(.right, r, otherFolder: folderLeft, relativePath: relativePath)
            case (nil, nil):
                break
            }
        }
    }

    private func takesPart(_ item: DiskItem, _ relativePath: String) -> Bool {
        item.type == .folder ? rules.allowsFolder(relativePath, name: item.name) : rules.allowsFile(relativePath, name: item.name)
    }

    private mutating func both(_ l: DiskItem, _ r: DiskItem, relativePath: String) throws {
        guard takesPart(l, relativePath), takesPart(r, relativePath) else { return }
        if l.type == .folder, r.type == .folder {
            try compare(folderLeft: l.url, folderRight: r.url, relative: relativePath)
            return
        }
        participants.left += 1
        participants.right += 1
        guard (l.type == .folder) == (r.type == .folder) else {
            skips.append(action(relativePath, .skip(.typeMismatch), source: l, target: r, toRight: true))
            return
        }
        if try same(l, r) {
            identical += 1
            return
        }
        switch options.direction {
        case .leftToRight:
            replaces.append(action(relativePath, .replace, source: l, target: r, toRight: true))
        case .rightToLeft:
            replaces.append(action(relativePath, .replace, source: r, target: l, toRight: false))
        case .twoWay:
            if abs(l.modified - r.modified) <= 2 {
                skips.append(action(relativePath, .skip(.undecided), source: l, target: r, toRight: true))
            } else if l.modified > r.modified {
                replaces.append(action(relativePath, .replace, source: l, target: r, toRight: true))
            } else {
                replaces.append(action(relativePath, .replace, source: r, target: l, toRight: false))
            }
        }
    }

    private func same(_ l: DiskItem, _ r: DiskItem) throws -> Bool {
        if l.type == .link || r.type == .link {
            return l.type == r.type && Disk.linkTarget(l.url) == Disk.linkTarget(r.url)
        }
        guard l.size == r.size else { return false }
        switch options.comparison {
        case .sizeAndDate:
            return abs(l.modified - r.modified) <= 2
        case .contents:
            do {
                return try Disk.sameContents(l.url, r.url)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw SyncError(.external, "Could not read \(l.name): \(error.localizedDescription)")
            }
        }
    }

    /// An item with no counterpart. The side that has it is the giver if the other side receives, and an extra otherwise.
    private mutating func onlyOn(_ side: Side, _ item: DiskItem, otherFolder: URL, relativePath: String) throws {
        guard takesPart(item, relativePath) else { return }
        if side == .left { participants.left += 1 } else { participants.right += 1 }
        let other: Side = side == .left ? .right : .left
        if receives(other) {
            try give(item, into: otherFolder, relativePath: relativePath, toRight: side == .left)
        } else if deletesExtras {
            try remove(item, relativePath: relativePath, toRight: side == .right)
        } else {
            extrasKept += 1
        }
    }

    /// Everything below a folder that takes part, or nil if part of it is filtered out or unreadable.
    private mutating func wholeTree(_ folder: DiskItem, relativePath: String) throws -> Int64? {
        guard let children = read(folder.url) else { return nil }
        var total: Int64 = 0
        var whole = true
        for child in children {
            try tick()
            let childPath = path(relativePath, child.name)
            guard takesPart(child, childPath) else { whole = false; continue }
            if child.type == .folder {
                if let size = try wholeTree(child, relativePath: childPath) { total += size } else { whole = false }
            } else {
                total += child.size
            }
        }
        return whole ? total : nil
    }

    private mutating func give(_ item: DiskItem, into folder: URL, relativePath: String, toRight: Bool) throws {
        let target = folder.appendingPathComponent(item.name)
        guard item.type == .folder else {
            copies.append(SyncAction(relativePath: relativePath, kind: .copy, source: item.url, target: target, bytes: item.size,
                                     targetIsNewer: false, towardRight: toRight, sourceMark: Disk.mark(of: item.url), targetMark: nil))
            return
        }
        if let bytes = try wholeTree(item, relativePath: relativePath) {
            copies.append(SyncAction(relativePath: relativePath, kind: .copy, source: item.url, target: target, bytes: bytes,
                                     targetIsNewer: false, towardRight: toRight, sourceMark: Disk.mark(of: item.url), targetMark: nil))
            return
        }
        // Part of it stays behind, so it goes piece by piece into a new folder
        guard let children = read(item.url) else { return }
        creates.append(SyncAction(relativePath: relativePath, kind: .createFolder, source: item.url, target: target, bytes: 0,
                                  targetIsNewer: false, towardRight: toRight, sourceMark: nil, targetMark: nil))
        for child in children {
            let childPath = path(relativePath, child.name)
            if takesPart(child, childPath) { try give(child, into: target, relativePath: childPath, toRight: toRight) }
        }
    }

    private mutating func remove(_ item: DiskItem, relativePath: String, toRight: Bool) throws {
        guard item.type == .folder else {
            deletes.append(SyncAction(relativePath: relativePath, kind: .delete, source: nil, target: item.url, bytes: item.size,
                                      targetIsNewer: false, towardRight: toRight, sourceMark: nil, targetMark: Disk.mark(of: item.url)))
            return
        }
        if let bytes = try wholeTree(item, relativePath: relativePath) {
            deletes.append(SyncAction(relativePath: relativePath, kind: .delete, source: nil, target: item.url, bytes: bytes,
                                      targetIsNewer: false, towardRight: toRight, sourceMark: nil, targetMark: Disk.mark(of: item.url)))
            return
        }
        // Holds something that does not take part: the folder stays, with that inside
        guard let children = read(item.url) else { return }
        for child in children {
            let childPath = path(relativePath, child.name)
            if takesPart(child, childPath) { try remove(child, relativePath: childPath, toRight: toRight) }
        }
    }

    private func action(_ relativePath: String, _ kind: SyncAction.Kind, source: DiskItem, target: DiskItem, toRight: Bool) -> SyncAction {
        SyncAction(relativePath: relativePath, kind: kind, source: source.url, target: target.url, bytes: source.size,
                   targetIsNewer: kind == .replace && options.direction != .twoWay && target.modified > source.modified + 2,
                   towardRight: toRight, sourceMark: Disk.mark(of: source.url), targetMark: Disk.mark(of: target.url))
    }

    private func depth(_ action: SyncAction) -> Int { action.relativePath.filter { $0 == "/" }.count }

    /// Whichever side receives must not end up with nothing while the other has nothing to give either.
    private var emptiesReceiver: Bool {
        guard deletesExtras, !deletes.isEmpty else { return false }
        let giver = options.direction == .leftToRight ? participants.left : participants.right
        return giver == 0
    }

    func finished() -> SyncPlan {
        var deletes = self.deletes
        var skips = self.skips
        if !problems.isEmpty {
            skips += deletes.map {
                SyncAction(relativePath: $0.relativePath, kind: .skip(.scanIncomplete), source: nil, target: $0.target, bytes: 0,
                           targetIsNewer: false, towardRight: $0.towardRight, sourceMark: nil, targetMark: nil)
            }
            deletes = []
        }
        let actions = creates.sorted { depth($0) < depth($1) } + copies + replaces
            + deletes.sorted { depth($0) > depth($1) } + skips
        return SyncPlan(left: left, right: right, options: options, actions: actions, identicalCount: identical,
                        extrasKept: extrasKept, problems: problems, wouldEmptyReceiver: problems.isEmpty && emptiesReceiver)
    }
}
