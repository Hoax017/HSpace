import ExtensionBridge
import Foundation
import HSpaceContracts
import HSpaceTestSupport
import Testing

private let token = String(repeating: "ab", count: 32)

private func link(_ query: String) -> URL {
    URL(string: "hspace://stash?\(query)")!
}

@Suite struct StashLinkTests {
    @Test func aLinkItMadeParsesBackToTheSamePaths() throws {
        let paths = ["/Users/me/a b.txt", "/Users/me/c+d&e=f?.txt", "/Users/me/é#1"]
        let url = try #require(StashLink.make(paths: paths, token: token))
        #expect(StashLink.isStashLink(url))
        #expect(StashLink.parse(url, expectedToken: token) == .success(paths))
    }

    @Test func noPathsOrTooManyMakeNoLink() {
        #expect(StashLink.make(paths: [], token: token) == nil)
        #expect(StashLink.make(paths: Array(repeating: "/a", count: StashLink.maxItems + 1), token: token) == nil)
    }

    @Test(arguments: [
        "path=/tmp/a", "token=&path=/tmp/a", "token=\(String(repeating: "cd", count: 32))&path=/tmp/a",
        "token=\(String(repeating: "ab", count: 31))&path=/tmp/a",
        "token=\(token)&token=\(token)&path=/tmp/a",
    ])
    func aMissingOrWrongSecretIsUntrusted(_ query: String) {
        #expect(StashLink.parse(link(query), expectedToken: token) == .failure(.untrusted))
    }

    @Test func anEmptyExpectedSecretTrustsNothing() {
        #expect(StashLink.parse(link("token=&path=/a"), expectedToken: "") == .failure(.untrusted))
    }

    @Test(arguments: [
        "hspace://open?token=x&path=/a", "hspace://stash/extra?token=x&path=/a", "hspace://user@stash?path=/a",
        "hspace://stash:9?path=/a", "https://stash?path=/a",
    ])
    func otherLinksAreNotStashLinks(_ text: String) {
        #expect(StashLink.parse(URL(string: text)!, expectedToken: token) == .failure(.notAStashLink))
    }

    @Test(arguments: [
        "path=relative", "path=~/x", "path=/tmp/../etc", "path=/tmp%00/x", "path=/a&action=delete", "path=",
    ])
    func badPathsAreRefused(_ query: String) {
        #expect(StashLink.parse(link("token=\(token)&\(query)"), expectedToken: token) == .failure(.invalidPath))
    }

    @Test func aTrustedLinkNeedsItems() {
        #expect(StashLink.parse(link("token=\(token)"), expectedToken: token) == .failure(.noItems))
    }

    @Test func tooManyItemsAreRefused() {
        let query = "token=\(token)" + String(repeating: "&path=/a", count: StashLink.maxItems + 1)
        #expect(StashLink.parse(link(query), expectedToken: token) == .failure(.tooManyItems))
    }
}

@Suite struct BadgeIndexTests {
    @Test func onlyStashedPathsGetTheBadge() {
        let index = BadgeIndex(paths: ["/Users/me/a.txt", "/Users/me/Folder/"])
        #expect(index.badge(forPath: "/Users/me/a.txt") == BadgeIndex.stashedBadge)
        #expect(index.badge(forPath: "/Users/me/Folder") == BadgeIndex.stashedBadge)
        #expect(index.badge(forPath: "/Users/me/./a.txt") == BadgeIndex.stashedBadge)
        #expect(index.badge(forPath: "/Users/me/b.txt") == nil)
        #expect(index.badge(forPath: "/Users/me") == nil)
    }

    @Test func changesNameAddedAndRemovedPathsOnly() {
        let old = BadgeIndex(paths: ["/a", "/b"])
        let new = BadgeIndex(paths: ["/b", "/c"])
        #expect(BadgeIndex.changes(from: old, to: new) == ["/a", "/c"])
        #expect(BadgeIndex.changes(from: new, to: new).isEmpty)
    }
}

@Suite struct BridgeStoreTests {
    @Test func nothingPublishedReadsAsNil() throws {
        let dir = try FaultFixture.tempDir()
        defer { FaultFixture.remove(dir) }
        #expect(try BridgeReader.read(from: dir).get() == nil)
    }

    @Test func publishWritesWhatTheReaderSeesForThisUserOnly() async throws {
        let dir = try FaultFixture.tempDir()
        defer { FaultFixture.remove(dir) }
        let bridge = BridgeLocation.directory(inSupport: dir)
        let publisher = BridgePublisher(directory: bridge)
        try await publisher.publish(stashedPaths: ["/x", "/y"])
        let snapshot = try #require(try BridgeReader.read(from: bridge).get())
        #expect(snapshot.stashedPaths == ["/x", "/y"])
        #expect(BridgeToken.isWellFormed(snapshot.token))
        #expect(try await publisher.currentToken() == snapshot.token)
        let attributes = try FileManager.default.attributesOfItem(
            atPath: bridge.appendingPathComponent(BridgeLocation.fileName).path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func theSecretSurvivesARelaunch() async throws {
        let dir = try FaultFixture.tempDir()
        defer { FaultFixture.remove(dir) }
        try await BridgePublisher(directory: dir).publish(stashedPaths: [])
        let first = try #require(try BridgeReader.read(from: dir).get()).token
        let relaunched = BridgePublisher(directory: dir, makeToken: { Issue.record("made a new secret"); return token })
        try await relaunched.publish(stashedPaths: ["/z"])
        #expect(try BridgeReader.read(from: dir).get()?.token == first)
    }

    @Test func aDamagedFileIsAnErrorForReadersAndReplacedByThePublisher() async throws {
        let dir = try FaultFixture.tempDir()
        defer { FaultFixture.remove(dir) }
        try FaultFixture.write(Data("{not json".utf8), to: dir.appendingPathComponent(BridgeLocation.fileName))
        guard case .failure(let error) = BridgeReader.read(from: dir) else { Issue.record("damaged file read"); return }
        #expect(error.errorClass == .external)
        try await BridgePublisher(directory: dir, makeToken: { token }).publish(stashedPaths: ["/a"])
        #expect(try BridgeReader.read(from: dir).get() == BridgeSnapshot(token: token, stashedPaths: ["/a"]))
    }

    @Test func aSnapshotFromAnotherVersionIsRefused() throws {
        let dir = try FaultFixture.tempDir()
        defer { FaultFixture.remove(dir) }
        let future = BridgeSnapshot(version: BridgeSnapshot.currentVersion + 1, token: token, stashedPaths: [])
        try FaultFixture.write(try JSONEncoder().encode(future), to: dir.appendingPathComponent(BridgeLocation.fileName))
        guard case .failure(let error) = BridgeReader.read(from: dir) else { Issue.record("future file read"); return }
        #expect(error.errorClass == .logic)
    }

    @Test func anUnreadableFileIsAnError() async throws {
        let dir = try FaultFixture.tempDir()
        defer { FaultFixture.remove(dir) }
        let file = dir.appendingPathComponent(BridgeLocation.fileName)
        try await BridgePublisher(directory: dir).publish(stashedPaths: [])
        try await FaultFixture.withMode(0o000, on: file) {
            guard case .failure = BridgeReader.read(from: dir) else { Issue.record("unreadable file read"); return }
        }
    }

    @Test func aReadOnlyFolderFailsThePublishWithAnError() async throws {
        let dir = try FaultFixture.tempDir()
        defer { FaultFixture.remove(dir) }
        try await FaultFixture.withReadOnly(dir) {
            await #expect(throws: BridgeError.self) {
                try await BridgePublisher(directory: dir, makeToken: { token }).publish(stashedPaths: ["/a"])
            }
        }
    }

    @Test func aFailingRandomSourceIsReported() async throws {
        struct NoEntropy: Error {}
        let dir = try FaultFixture.tempDir()
        defer { FaultFixture.remove(dir) }
        let publisher = BridgePublisher(directory: dir, makeToken: { throw NoEntropy() })
        await #expect(throws: BridgeError.self) { try await publisher.publish(stashedPaths: []) }
        #expect(try BridgeReader.read(from: dir).get() == nil)
    }

    @Test func realSupportFolderIsUnderTheUsersHome() {
        let support = BridgeLocation.appSupportOutsideSandbox().path
        #expect(support.hasSuffix("/Library/Application Support/HSpace"))
        #expect(!support.contains("/Containers/"))
    }
}
