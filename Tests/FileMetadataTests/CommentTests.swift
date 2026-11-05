import Foundation
import FileMetadata
import HSpaceContracts
import HSpaceTestSupport
import Testing

private let commentAttribute = "com.apple.metadata:kMDItemFinderComment"

/// Records what would be sent to Finder
final class FakeFinder: FinderCommentPushing, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String: [URL]] = [:]
    var failure: MetadataError?

    func push(comment: String, to urls: [URL]) async throws {
        if let failure { throw failure }
        lock.withLock { stored[comment] = urls }
    }

    var calls: [String: [URL]] {
        lock.lock(); defer { lock.unlock() }
        return stored
    }
}

@Suite struct CommentTests {
    let engine = FileMetadata()

    private func file(in dir: URL, _ name: String = "a.txt") throws -> URL {
        let url = dir.appendingPathComponent(name)
        try FaultFixture.write(to: url)
        return url
    }

    @Test func commentLandsInTheRealAttribute() async throws {
        let dir = try FaultFixture.tempDir("hspace-comment")
        defer { FaultFixture.remove(dir) }
        let url = try file(in: dir)

        _ = try await engine.apply(.comment("Quarterly report"), to: [url])

        let data = try #require(rawAttribute(commentAttribute, of: url))
        var format = PropertyListSerialization.PropertyListFormat.xml
        let stored = try PropertyListSerialization.propertyList(from: data, format: &format) as? String
        #expect(format == .binary)
        #expect(stored == "Quarterly report")
        #expect(try engine.comment(of: url) == "Quarterly report")
    }

    @Test func aCommentWrittenByTheSystemFormatIsRead() throws {
        let dir = try FaultFixture.tempDir("hspace-comment")
        defer { FaultFixture.remove(dir) }
        let url = try file(in: dir)
        let data = try PropertyListSerialization.data(fromPropertyList: "From Finder", format: .binary, options: 0)
        setRawAttribute(commentAttribute, data, of: url)
        #expect(try engine.comment(of: url) == "From Finder")
    }

    @Test func emptyMeansNoComment() async throws {
        let dir = try FaultFixture.tempDir("hspace-comment")
        defer { FaultFixture.remove(dir) }
        let url = try file(in: dir)
        _ = try await engine.apply(.comment("x"), to: [url])
        _ = try await engine.apply(.comment(""), to: [url])
        #expect(rawAttribute(commentAttribute, of: url) == nil)
        #expect(try engine.comment(of: url) == nil)
    }

    @Test func unicodeAndLineBreaksSurvive() async throws {
        let dir = try FaultFixture.tempDir("hspace-comment")
        defer { FaultFixture.remove(dir) }
        let url = try file(in: dir)
        let text = "Première ligne\n第二行 🗂"
        _ = try await engine.apply(.comment(text), to: [url])
        #expect(try engine.comment(of: url) == text)
    }

    @Test func undoAndRedo() async throws {
        let dir = try FaultFixture.tempDir("hspace-comment")
        defer { FaultFixture.remove(dir) }
        let url = try file(in: dir)
        _ = try await engine.apply(.comment("old"), to: [url])

        let applied = try await engine.apply(.comment("new"), to: [url])
        let undone = try await engine.restore(applied.changed)
        #expect(try engine.comment(of: url) == "old")
        _ = try await engine.restore(undone.changed)
        #expect(try engine.comment(of: url) == "new")
    }

    @Test func anUnchangedCommentIsLeftAlone() async throws {
        let dir = try FaultFixture.tempDir("hspace-comment")
        defer { FaultFixture.remove(dir) }
        let url = try file(in: dir)
        _ = try await engine.apply(.comment("same"), to: [url])
        let again = try await engine.apply(.comment("same"), to: [url])
        #expect(again.changed.isEmpty)
    }

    @Test func tagsAndCommentsDoNotDisturbEachOther() async throws {
        let dir = try FaultFixture.tempDir("hspace-comment")
        defer { FaultFixture.remove(dir) }
        let url = try file(in: dir)
        let red = FinderTag(name: "Red", color: .red)
        try engine.setTags([red], on: url)
        _ = try await engine.apply(.comment("note"), to: [url])
        let found = try await engine.read([url])
        #expect(found[url] == ItemMetadata(tags: [red], comment: "note"))
    }

    @Test func noPermissionFailsPerItem() async throws {
        let dir = try FaultFixture.tempDir("hspace-comment")
        defer { FaultFixture.remove(dir) }
        let url = try file(in: dir)
        try await FaultFixture.withMode(0o444, on: url) {
            let result = try await engine.apply(.comment("x"), to: [url])
            #expect(result.failures.first?.errorClass == .external)
        }
    }

    @Test func damagedDataIsNeverOverwritten() async throws {
        let dir = try FaultFixture.tempDir("hspace-comment")
        defer { FaultFixture.remove(dir) }
        let url = try file(in: dir)
        let junk = Data([0xFF, 0xFE, 0x00, 0x01])
        setRawAttribute(commentAttribute, junk, of: url)
        let result = try await engine.apply(.comment("x"), to: [url])
        #expect(result.failures.count == 1)
        #expect(rawAttribute(commentAttribute, of: url) == junk)
    }

    @Test func anEjectedVolumeFailsPerItem() async throws {
        let volume = try ScratchVolume()
        let url = try file(in: volume.url)
        try volume.eject()
        let result = try await engine.apply(.comment("x"), to: [url])
        #expect(result.failures.first?.errorClass == .external)
    }

    @Test func cancellingPutsCommentsBack() async throws {
        let dir = try FaultFixture.tempDir("hspace-comment")
        defer { FaultFixture.remove(dir) }
        let urls = try (0..<20).map { try file(in: dir, "f\($0)") }
        let engine = engine
        let task = Task {
            try await engine.apply(.comment("x"), to: urls) { done, _ in
                if done == 5 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        for url in urls { #expect(try engine.comment(of: url) == nil) }
    }
}

@Suite struct FinderPushTests {
    let engine = FileMetadata()

    @Test func itemsWithTheSameCommentGoTogether() async throws {
        let dir = try FaultFixture.tempDir("hspace-comment")
        defer { FaultFixture.remove(dir) }
        let urls = try ["a", "b", "c"].map { name in
            let url = dir.appendingPathComponent(name)
            try FaultFixture.write(to: url)
            return url
        }
        _ = try await engine.apply(.comment("one"), to: [urls[0], urls[1]])
        let finder = FakeFinder()

        let problem = await engine.pushComments(of: urls, using: finder)

        #expect(problem == nil)
        #expect(finder.calls == ["one": [urls[0], urls[1]], "": [urls[2]]])
    }

    @Test func refusalIsReturnedNotThrown() async throws {
        let dir = try FaultFixture.tempDir("hspace-comment")
        defer { FaultFixture.remove(dir) }
        let url = dir.appendingPathComponent("a")
        try FaultFixture.write(to: url)
        let finder = FakeFinder()
        finder.failure = try #require(await refusal(engine, dir))

        #expect(await engine.pushComments(of: [url], using: finder) != nil)
        #expect(finder.calls.isEmpty)
    }

    /// A real error value, since its initializer is private to the pod
    private func refusal(_ engine: FileMetadata, _ dir: URL) async -> MetadataError? {
        do {
            _ = try engine.tags(of: dir.appendingPathComponent("gone"))
            return nil
        } catch {
            return error as? MetadataError
        }
    }

    @Test func valuesTravelAsArgumentsNeverAsScript() {
        let hostile = "\" & (do shell script \"rm -rf /\") & \""
        let url = URL(fileURLWithPath: "/tmp/odd \"name\".txt")
        let args = OsascriptFinderComments.arguments(comment: hostile, urls: [url])
        let script = args.enumerated().filter { $0.offset % 2 == 1 && args[$0.offset - 1] == "-e" }.map(\.element)
        #expect(!script.joined().contains("rm -rf"))
        #expect(Array(args.suffix(2)) == [hostile, url.path])
    }
}
