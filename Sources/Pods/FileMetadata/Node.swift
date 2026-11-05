import Foundation
import HSpaceContracts

/// Reads and changes file metadata. No stored state, so one value can be shared freely (Axiom 2).
public struct FileMetadata: Sendable {
    public init() {}

    // MARK: Reading

    /// Throws on damaged tag data or an unreachable item, so a caller about to edit never starts from a wrong list.
    public func tags(of url: URL) throws -> [FinderTag] {
        try readTags(of: url)
    }

    public func comment(of url: URL) throws -> String? {
        try readComment(of: url)
    }

    /// Reads many items for display. An item that cannot be read is simply left out: decoration must not hurt the listing.
    /// Throws only `CancellationError`.
    public func read(_ urls: [URL]) async throws -> [URL: ItemMetadata] {
        var result: [URL: ItemMetadata] = [:]
        result.reserveCapacity(urls.count)
        for (index, url) in urls.enumerated() {
            if index % 64 == 0 {
                try Task.checkCancellation()
                await Task.yield()
            }
            let found = ItemMetadata(tags: (try? readTags(of: url)) ?? [], comment: try? readComment(of: url),
                                     color: try? readColor(of: url),
                                     hasCustomIcon: (try? hasCustomIcon(url)) ?? false)
            if found != ItemMetadata() { result[url] = found }
        }
        try Task.checkCancellation()
        return result
    }

    // MARK: Changing

    /// Replaces an item's tags.
    public func setTags(_ tags: [FinderTag], on url: URL) throws {
        try validate(tags)
        try writeTags(tags, to: url)
    }

    /// Applies one edit to every item. A failing item does not stop the others and lands in `failures`.
    /// When cancelled, items already changed are put back and `CancellationError` is thrown, so a cancelled batch leaves nothing half done.
    public func apply(_ edit: MetadataEdit, to urls: [URL],
                      progress: MetadataProgress = { _, _ in }) async throws -> MetadataBatchResult {
        switch edit {
        case .tags(let add, _): try validate(add)
        case .comment, .color, .folderIcon: break
        }
        // Drawn once, before any write: a bad spec must not stop halfway
        var icon: Data?
        if case .folderIcon(let spec?) = edit { icon = try FolderIconRenderer.render(spec) }
        return try await run(urls, progress: progress) { url in
            switch edit {
            case .tags(let add, let remove):
                let before = try readTags(of: url)
                let after = TagQuery.merged(before, add: add, remove: remove)
                guard after != before else { return nil }
                try writeTags(after, to: url)
                return MetadataChange(url: url, before: .tags(before))
            case .comment(let comment):
                let before = try readComment(of: url)
                let after = comment?.isEmpty == true ? nil : comment
                guard after != before else { return nil }
                try writeComment(after, to: url)
                return MetadataChange(url: url, before: .comment(before))
            case .color(let color):
                let before = try readColor(of: url)
                guard color != before else { return nil }
                try writeColor(color, to: url)
                return MetadataChange(url: url, before: .color(before))
            case .folderIcon:
                let before = try currentFolderIcon(of: url)
                guard icon != nil || before != nil else { return nil }
                try writeFolderIcon(icon, to: url)
                return MetadataChange(url: url, before: .folderIcon(before))
            }
        }
    }

    /// Puts earlier values back (undo). Returns what it replaced, so the same call also redoes.
    public func restore(_ changes: [MetadataChange],
                        progress: MetadataProgress = { _, _ in }) async throws -> MetadataBatchResult {
        let values = Dictionary(changes.map { ($0.url, $0.before) }) { first, _ in first }
        return try await run(changes.map(\.url), progress: progress) { url in
            guard let value = values[url] else { return nil }
            return try swap(value, on: url)
        }
    }

    /// Passes the items' stored comments on to Finder, one call per distinct comment. Returns what went wrong:
    /// the comments are already saved, so this is a warning for the user and not a failed change.
    public func pushComments(of urls: [URL], using pusher: any FinderCommentPushing) async -> MetadataError? {
        var groups: [String: [URL]] = [:]
        for url in urls {
            do {
                groups[try readComment(of: url) ?? "", default: []].append(url)
            } catch {
                return error as? MetadataError
            }
        }
        for (comment, members) in groups.sorted(by: { $0.key < $1.key }) {
            do {
                try await pusher.push(comment: comment, to: members)
            } catch {
                return error as? MetadataError ?? MetadataError(.transient, error.localizedDescription)
            }
        }
        return nil
    }

    // MARK: Private

    private func run(_ urls: [URL], progress: MetadataProgress,
                     change: (URL) throws -> MetadataChange?) async throws -> MetadataBatchResult {
        var changed: [MetadataChange] = []
        var failures: [OperationFailure] = []
        for (index, url) in urls.enumerated() {
            if Task.isCancelled {
                try rollBack(changed)
                throw CancellationError()
            }
            do {
                if let done = try change(url) { changed.append(done) }
            } catch {
                failures.append(failure(error, url))
            }
            progress(index + 1, urls.count)
            await Task.yield()
        }
        return MetadataBatchResult(changed: changed, failures: failures)
    }

    private func swap(_ value: MetadataValue, on url: URL) throws -> MetadataChange {
        switch value {
        case .tags(let tags):
            let current = try readTags(of: url)
            try writeTags(tags, to: url)
            return MetadataChange(url: url, before: .tags(current))
        case .comment(let comment):
            let current = try readComment(of: url)
            try writeComment(comment, to: url)
            return MetadataChange(url: url, before: .comment(current))
        case .color(let color):
            let current = try readColor(of: url)
            try writeColor(color, to: url)
            return MetadataChange(url: url, before: .color(current))
        case .folderIcon(let icon):
            let current = try currentFolderIcon(of: url)
            try writeFolderIcon(icon, to: url)
            return MetadataChange(url: url, before: .folderIcon(current))
        }
    }

    private func rollBack(_ changed: [MetadataChange]) throws {
        var stuck: [String] = []
        for item in changed.reversed() {
            do {
                _ = try swap(item.before, on: item.url)
            } catch {
                stuck.append(item.url.lastPathComponent)
            }
        }
        guard let first = stuck.first else { return }
        throw MetadataError(.external, "Cancelled, but \(stuck.count) item(s) kept the change, starting with \"\(first)\"")
    }

    private func failure(_ error: any Error, _ url: URL) -> OperationFailure {
        let classified = error as? any ClassifiedError
        return OperationFailure(url: url, errorClass: classified?.errorClass ?? .transient,
                                message: classified?.localizedDescription ?? error.localizedDescription)
    }
}
