import Foundation
import FileMetadata
import HSpaceContracts
import HSpaceTestSupport
import Testing

/// Reads the attribute with no help from the pod, so these tests prove the on-disk format and not just a round trip.
func rawAttribute(_ name: String, of url: URL, noFollow: Bool = true) -> Data? {
    let options = noFollow ? XATTR_NOFOLLOW : 0
    let size = getxattr(url.path, name, nil, 0, 0, options)
    guard size >= 0 else { return nil }
    var data = Data(count: size)
    _ = data.withUnsafeMutableBytes { getxattr(url.path, name, $0.baseAddress, size, 0, options) }
    return data
}

func setRawAttribute(_ name: String, _ data: Data, of url: URL) {
    _ = data.withUnsafeBytes { setxattr(url.path, name, $0.baseAddress, data.count, 0, 0) }
}

/// What macOS itself reports for the item
func systemTagNames(_ url: URL) throws -> [String] {
    var fresh = url
    fresh.removeAllCachedResourceValues()
    return try fresh.resourceValues(forKeys: [.tagNamesKey]).tagNames ?? []
}

private let tagAttribute = "com.apple.metadata:_kMDItemUserTags"
private let red = FinderTag(name: "Red", color: .red)
private let blue = FinderTag(name: "Blue", color: .blue)

@Suite struct FinderCompatibilityTests {
    let engine = FileMetadata()

    @Test func tagsLandInTheRealAttributeInFindersFormat() throws {
        let dir = try FaultFixture.tempDir("hspace-tags")
        defer { FaultFixture.remove(dir) }
        let file = dir.appendingPathComponent("a.txt")
        try FaultFixture.write(to: file)

        try engine.setTags([red, FinderTag(name: "Work")], on: file)

        let data = try #require(rawAttribute(tagAttribute, of: file))
        var format = PropertyListSerialization.PropertyListFormat.xml
        let list = try PropertyListSerialization.propertyList(from: data, format: &format) as? [String]
        #expect(format == .binary)
        #expect(list == ["Red\n6", "Work\n0"])
    }

    @Test func macOSReadsWhatWeWrite() throws {
        let dir = try FaultFixture.tempDir("hspace-tags")
        defer { FaultFixture.remove(dir) }
        let file = dir.appendingPathComponent("a.txt")
        try FaultFixture.write(to: file)
        try engine.setTags([red, FinderTag(name: "Work")], on: file)
        #expect(try systemTagNames(file) == ["Red", "Work"])
    }

    @Test func weReadWhatMacOSWrites() throws {
        let dir = try FaultFixture.tempDir("hspace-tags")
        defer { FaultFixture.remove(dir) }
        let file = dir.appendingPathComponent("a.txt")
        try FaultFixture.write(to: file)
        try (file as NSURL).setResourceValue(["Blue", "Project"], forKey: .tagNamesKey)
        #expect(try engine.tags(of: file) == [blue, FinderTag(name: "Project")])
    }

    /// Clearing only the attribute leaves the Finder label behind, and macOS shows that label as a tag again.
    @Test func removingTheLastTagLeavesNoGhostInFinder() throws {
        let dir = try FaultFixture.tempDir("hspace-tags")
        defer { FaultFixture.remove(dir) }
        let file = dir.appendingPathComponent("a.txt")
        try FaultFixture.write(to: file)
        try (file as NSURL).setResourceValue(["Blue"], forKey: .tagNamesKey)

        try engine.setTags([], on: file)

        #expect(try systemTagNames(file).isEmpty)
        #expect(try engine.tags(of: file).isEmpty)
    }

    @Test func finderLabelFollowsTheLastColouredTagLikeMacOS() throws {
        let dir = try FaultFixture.tempDir("hspace-tags")
        defer { FaultFixture.remove(dir) }
        let ours = dir.appendingPathComponent("ours")
        let system = dir.appendingPathComponent("system")
        try FaultFixture.write(to: ours)
        try FaultFixture.write(to: system)

        try engine.setTags([red, blue, FinderTag(name: "Work")], on: ours)
        try (system as NSURL).setResourceValue(["Red", "Blue", "Work"], forKey: .tagNamesKey)

        let info = "com.apple.FinderInfo"
        #expect(rawAttribute(info, of: ours) == rawAttribute(info, of: system))
    }

    @Test func aFinderLabelAloneReadsAsATag() throws {
        let dir = try FaultFixture.tempDir("hspace-tags")
        defer { FaultFixture.remove(dir) }
        let file = dir.appendingPathComponent("a.txt")
        try FaultFixture.write(to: file)
        var info = Data(count: 32)
        info[9] = 12
        setRawAttribute("com.apple.FinderInfo", info, of: file)
        #expect(try engine.tags(of: file) == [red])
    }

    @Test func otherFinderInfoSurvives() throws {
        let dir = try FaultFixture.tempDir("hspace-tags")
        defer { FaultFixture.remove(dir) }
        let file = dir.appendingPathComponent("a.txt")
        try FaultFixture.write(to: file)
        var info = Data(count: 32)
        info[0] = 0x54           // file type
        info[8] = 0x04           // custom-icon flag
        setRawAttribute("com.apple.FinderInfo", info, of: file)

        try engine.setTags([red], on: file)
        try engine.setTags([], on: file)

        let after = try #require(rawAttribute("com.apple.FinderInfo", of: file))
        #expect(after == info)
    }

    @Test func foldersCarryTagsToo() throws {
        let dir = try FaultFixture.tempDir("hspace-tags")
        defer { FaultFixture.remove(dir) }
        try engine.setTags([blue], on: dir)
        #expect(try systemTagNames(dir) == ["Blue"])
    }

    @Test func aSymlinkIsTaggedNotItsTarget() throws {
        let dir = try FaultFixture.tempDir("hspace-tags")
        defer { FaultFixture.remove(dir) }
        let file = dir.appendingPathComponent("a.txt")
        try FaultFixture.write(to: file)
        let link = dir.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)

        try engine.setTags([red], on: link)

        #expect(try engine.tags(of: link) == [red])
        #expect(try engine.tags(of: file).isEmpty)
        #expect(rawAttribute(tagAttribute, of: link) != nil)
    }
}

@Suite struct TagFailureTests {
    let engine = FileMetadata()

    @Test func noPermissionIsReported() async throws {
        let dir = try FaultFixture.tempDir("hspace-tags")
        defer { FaultFixture.remove(dir) }
        let file = dir.appendingPathComponent("a.txt")
        try FaultFixture.write(to: file)
        try await FaultFixture.withMode(0o444, on: file) {
            #expect {
                try engine.setTags([red], on: file)
            } throws: { error in
                (error as? MetadataError)?.errorClass == .external
            }
        }
        #expect(try engine.tags(of: file).isEmpty)
    }

    @Test func aMissingItemIsReported() throws {
        let dir = try FaultFixture.tempDir("hspace-tags")
        defer { FaultFixture.remove(dir) }
        let gone = dir.appendingPathComponent("gone")
        #expect(throws: MetadataError.self) { try engine.tags(of: gone) }
        #expect(throws: MetadataError.self) { try engine.setTags([red], on: gone) }
    }

    @Test func damagedTagDataIsNeverOverwritten() async throws {
        let dir = try FaultFixture.tempDir("hspace-tags")
        defer { FaultFixture.remove(dir) }
        let file = dir.appendingPathComponent("a.txt")
        try FaultFixture.write(to: file)
        let junk = Data("not a property list".utf8)
        setRawAttribute(tagAttribute, junk, of: file)

        #expect(throws: MetadataError.self) { try engine.tags(of: file) }
        let result = try await engine.apply(.tags(add: [red], remove: []), to: [file])

        #expect(result.changed.isEmpty)
        #expect(result.failures.count == 1)
        #expect(rawAttribute(tagAttribute, of: file) == junk)
    }

    @Test func badNamesAreRefusedBeforeAnyWrite() async throws {
        let dir = try FaultFixture.tempDir("hspace-tags")
        defer { FaultFixture.remove(dir) }
        let file = dir.appendingPathComponent("a.txt")
        try FaultFixture.write(to: file)
        for bad in ["", "  ", "two\nlines"] {
            await #expect(throws: MetadataError.self) {
                try await engine.apply(.tags(add: [FinderTag(name: bad)], remove: []), to: [file])
            }
        }
        #expect(rawAttribute(tagAttribute, of: file) == nil)
    }

    @Test func anEjectedVolumeFailsPerItem() async throws {
        let volume = try ScratchVolume()
        let file = volume.url.appendingPathComponent("a.txt")
        try FaultFixture.write(to: file)
        try volume.eject()
        let result = try await engine.apply(.tags(add: [red], remove: []), to: [file])
        #expect(result.changed.isEmpty)
        #expect(result.failures.first?.errorClass == .external)
    }

    @Test func aFullDiskFailsCleanly() async throws {
        let volume = try ScratchVolume()
        let file = volume.url.appendingPathComponent("a.txt")
        try FaultFixture.write(to: file)
        try volume.fill(leaving: 0)
        // A small attribute can still fit in the inode, so a large list makes sure the disk is what stops it
        let many = (0..<400).map { FinderTag(name: "A tag with a rather long name \($0)") }
        let result = try await engine.apply(.tags(add: many, remove: []), to: [file])
        if let failure = result.failures.first {
            #expect(failure.errorClass == .external)
            #expect(try engine.tags(of: file).isEmpty)
        } else {
            #expect(try engine.tags(of: file).count == many.count)
        }
    }
}

@Suite struct TagBatchTests {
    let engine = FileMetadata()

    private func files(_ count: Int, in dir: URL) throws -> [URL] {
        try (0..<count).map { index in
            let url = dir.appendingPathComponent("file\(index)")
            try FaultFixture.write(to: url)
            return url
        }
    }

    @Test func addingKeepsOtherTags() async throws {
        let dir = try FaultFixture.tempDir("hspace-tags")
        defer { FaultFixture.remove(dir) }
        let urls = try files(2, in: dir)
        try engine.setTags([FinderTag(name: "Keep")], on: urls[0])

        let result = try await engine.apply(.tags(add: [red], remove: []), to: urls)

        #expect(result.changed.count == 2)
        #expect(try engine.tags(of: urls[0]) == [FinderTag(name: "Keep"), red])
        #expect(try engine.tags(of: urls[1]) == [red])
    }

    @Test func aFailureDoesNotStopTheRest() async throws {
        let dir = try FaultFixture.tempDir("hspace-tags")
        defer { FaultFixture.remove(dir) }
        var urls = try files(2, in: dir)
        urls.insert(dir.appendingPathComponent("gone"), at: 1)

        let result = try await engine.apply(.tags(add: [red], remove: []), to: urls)

        #expect(result.changed.map(\.url) == [urls[0], urls[2]])
        #expect(result.failures.map(\.url) == [urls[1]])
    }

    @Test func itemsThatAlreadyMatchAreLeftAlone() async throws {
        let dir = try FaultFixture.tempDir("hspace-tags")
        defer { FaultFixture.remove(dir) }
        let urls = try files(1, in: dir)
        try engine.setTags([red], on: urls[0])
        let result = try await engine.apply(.tags(add: [FinderTag(name: "RED")], remove: []), to: urls)
        #expect(result.changed.isEmpty)
        #expect(result.failures.isEmpty)
    }

    @Test func restoreUndoesAndRedoes() async throws {
        let dir = try FaultFixture.tempDir("hspace-tags")
        defer { FaultFixture.remove(dir) }
        let urls = try files(2, in: dir)
        try engine.setTags([blue], on: urls[0])

        let applied = try await engine.apply(.tags(add: [red], remove: ["Blue"]), to: urls)
        let undone = try await engine.restore(applied.changed)
        #expect(try engine.tags(of: urls[0]) == [blue])
        #expect(try engine.tags(of: urls[1]).isEmpty)

        _ = try await engine.restore(undone.changed)
        #expect(try engine.tags(of: urls[0]) == [red])
        #expect(try engine.tags(of: urls[1]) == [red])
    }

    @Test func progressCountsEveryItem() async throws {
        let dir = try FaultFixture.tempDir("hspace-tags")
        defer { FaultFixture.remove(dir) }
        let urls = try files(3, in: dir)
        let seen = Seen()
        _ = try await engine.apply(.tags(add: [red], remove: []), to: urls) { done, total in
            seen.add(done, total)
        }
        #expect(seen.values == [[1, 3], [2, 3], [3, 3]])
    }

    @Test func cancellingPutsEverythingBack() async throws {
        let dir = try FaultFixture.tempDir("hspace-tags")
        defer { FaultFixture.remove(dir) }
        let urls = try files(50, in: dir)
        let started = Seen()
        let engine = engine
        let task = Task {
            try await engine.apply(.tags(add: [red], remove: []), to: urls) { done, total in
                started.add(done, total)
                if done == 10 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        for url in urls {
            #expect(try engine.tags(of: url).isEmpty)
        }
    }

    @Test func bulkReadSkipsWhatItCannotRead() async throws {
        let dir = try FaultFixture.tempDir("hspace-tags")
        defer { FaultFixture.remove(dir) }
        let urls = try files(3, in: dir)
        try engine.setTags([red], on: urls[0])
        setRawAttribute(tagAttribute, Data("junk".utf8), of: urls[1])
        let gone = dir.appendingPathComponent("gone")

        let found = try await engine.read(urls + [gone])

        #expect(found == [urls[0]: ItemMetadata(tags: [red])])
    }

    @Test func bulkReadStopsWhenCancelled() async throws {
        let engine = engine
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await engine.read([URL(fileURLWithPath: "/tmp")])
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}

@Suite struct TagQueryTests {
    @Test func namesMatchWithoutCase() {
        #expect(TagQuery.matches([red], anyOf: ["red"]))
        #expect(!TagQuery.matches([red], anyOf: ["blue"]))
        #expect(!TagQuery.matches([], anyOf: ["red"]))
    }

    @Test func mergeKeepsOrderAndColour() {
        let merged = TagQuery.merged([red, blue], add: [FinderTag(name: "BLUE"), FinderTag(name: "New")], remove: ["red"])
        #expect(merged == [blue, FinderTag(name: "New")])
    }

    @Test func knownTagsAreUniqueAndPreferColour() {
        let known = TagQuery.known(in: [[FinderTag(name: "RED")], [red, blue]])
        #expect(known == [blue, red])
    }

    @Test func sortingKeepsUntaggedLastInBothDirections() {
        let items = ["b", "none", "a", "a2"]
        let tags: [String: [FinderTag]] = ["a": [blue], "a2": [blue], "b": [red]]
        #expect(TagQuery.sorted(items, ascending: true) { tags[$0] ?? [] } == ["a", "a2", "b", "none"])
        #expect(TagQuery.sorted(items, ascending: false) { tags[$0] ?? [] } == ["b", "a", "a2", "none"])
    }
}

/// Collects values from `@Sendable` closures
final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [[Int]] = []

    func add(_ done: Int, _ total: Int) {
        lock.lock(); defer { lock.unlock() }
        stored.append([done, total])
    }

    var values: [[Int]] {
        lock.lock(); defer { lock.unlock() }
        return stored
    }
}
