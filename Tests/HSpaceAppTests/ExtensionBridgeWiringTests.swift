import ExtensionBridge
import Foundation
import HSpaceTestSupport
import StashStore
import Testing
@testable import HSpaceApp

private let secret = String(repeating: "0f", count: 32)

/// The repository root, for checks on the extension bundles' source files
private let repository = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

@Suite struct StashLinkCheckTests {
    @Test func aTrustedLinkToLocalItemsGivesThoseItems() throws {
        let link = try #require(StashLink.make(paths: ["/Users/me/a.txt", "/tmp/b"], token: secret))
        #expect(ExtensionBridgeHub.stashTargets(of: link, token: secret)
            == .success([URL(fileURLWithPath: "/Users/me/a.txt"), URL(fileURLWithPath: "/tmp/b")]))
    }

    @Test func aLinkWithoutTheSecretIsRefused() throws {
        let forged = try #require(StashLink.make(paths: ["/tmp/a"], token: String(repeating: "aa", count: 32)))
        #expect(ExtensionBridgeHub.stashTargets(of: forged, token: secret) == .failure(.link(.untrusted)))
        let bare = try #require(URL(string: "hspace://stash?path=/tmp/a"))
        #expect(ExtensionBridgeHub.stashTargets(of: bare, token: secret) == .failure(.link(.untrusted)))
    }

    @Test(arguments: ["/net/host/share/a", "/Volumes/../net/x", "/.vol/1/2"])
    func networkPathsAreRefusedEvenWithTheSecret(_ path: String) throws {
        let link = try #require(StashLink.make(paths: ["/tmp/ok", path], token: secret))
        guard case .failure = ExtensionBridgeHub.stashTargets(of: link, token: secret) else {
            Issue.record("accepted \(path)")
            return
        }
    }

    @Test func refusalsAreWordedAndNeverRepeatAPath() throws {
        // The test bundle has no app strings, so the keys are looked up in the strings file itself
        let table = try #require(NSDictionary(contentsOf: repository.appendingPathComponent("Resources/en.lproj/Localizable.strings")))
        let refusals: [StashLinkRefusal] = [
            .link(.untrusted), .link(.notAStashLink), .link(.tooManyItems), .link(.noItems), .link(.invalidPath),
            .path(.remotePath), .path(.invalidPath), .noSecret,
        ]
        for refusal in refusals {
            let text = try #require(table[refusal.message] as? String, "\(refusal) has no string")
            #expect(!text.isEmpty)
            #expect(!text.contains("/"))
        }
    }
}

@MainActor
@Suite struct ExtensionBridgeHubTests {
    @Test func stashChangesArePublishedForTheExtensions() async throws {
        let dir = try FaultFixture.tempDir()
        defer { FaultFixture.remove(dir) }
        let file = dir.appendingPathComponent("stashed.txt")
        try FaultFixture.write(to: file)
        let store = StashStore(directory: dir)
        let items = try await store.add([file])
        let hub = ExtensionBridgeHub(supportDirectory: dir)
        hub.stashChanged(items, store: store)
        await hub.settle()
        let bridge = BridgeLocation.directory(inSupport: dir)
        let published = try BridgeReader.read(from: bridge).get()?.stashedPaths ?? []
        // The bookmark resolves through /private, the fixture path does not
        #expect(published.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } == [file.resolvingSymlinksInPath().path])

        hub.stashChanged([], store: store)
        await hub.settle()
        #expect(try BridgeReader.read(from: bridge).get()?.stashedPaths == [])
    }

    @Test func theLinkSecretIsTheOnePublished() async throws {
        let dir = try FaultFixture.tempDir()
        defer { FaultFixture.remove(dir) }
        let hub = ExtensionBridgeHub(supportDirectory: dir)
        hub.stashChanged([], store: StashStore(directory: dir))
        await hub.settle()
        let token = try #require(try BridgeReader.read(from: BridgeLocation.directory(inSupport: dir)).get()).token
        let link = try #require(StashLink.make(paths: ["/tmp/a"], token: token))
        #expect(await hub.stashTargets(of: link) == .success([URL(fileURLWithPath: "/tmp/a")]))
    }

    @Test func aFailedPublishReachesTheUser() async throws {
        let dir = try FaultFixture.tempDir()
        defer { FaultFixture.remove(dir) }
        let hub = ExtensionBridgeHub(supportDirectory: dir)
        var messages: [String] = []
        hub.onError = { messages.append($0) }
        // A support folder where nothing can be created
        #expect(chmod(dir.path, 0o555) == 0)
        hub.stashChanged([], store: StashStore(directory: dir))
        await hub.settle()
        chmod(dir.path, 0o755)
        #expect(messages.count == 1)
    }
}

/// One app extension: its folder under Support/Extensions, its executable target and the file holding its principal class
struct ExtensionBundle: Sendable, CustomTestStringConvertible {
    let folder: String
    let executable: String
    let point: String
    let source: String
    var testDescription: String { folder }

    static let all = [
        ExtensionBundle(folder: "FinderSync", executable: "HSpaceFinderSync", point: "com.apple.FinderSync",
                        source: "FinderSyncExtension.swift"),
        ExtensionBundle(folder: "Share", executable: "HSpaceShare", point: "com.apple.share-services",
                        source: "ShareViewController.swift"),
    ]
}

@Suite struct ExtensionBundleTests {
    private func plist(_ path: String) throws -> [String: Any] {
        let data = try Data(contentsOf: repository.appendingPathComponent(path))
        return try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    private func source(_ bundle: ExtensionBundle) throws -> String {
        try String(contentsOf: repository.appendingPathComponent("Sources/\(bundle.executable)/\(bundle.source)"), encoding: .utf8)
    }

    @Test(arguments: ExtensionBundle.all)
    func infoPlistMatchesTheCode(_ bundle: ExtensionBundle) throws {
        let info = try plist("Support/Extensions/\(bundle.folder)/Info.plist")
        let ext = try #require(info["NSExtension"] as? [String: Any])
        #expect(ext["NSExtensionPointIdentifier"] as? String == bundle.point)
        let principal = try #require(ext["NSExtensionPrincipalClass"] as? String)
        #expect(try source(bundle).contains("@objc(\(principal))"))
        #expect(info["CFBundleExecutable"] as? String == bundle.executable)
        #expect((info["CFBundleIdentifier"] as? String)?.hasPrefix("com.hoax017.hspace.") == true)
        #expect(info["CFBundlePackageType"] as? String == "XPC!")
    }

    @Test(arguments: ExtensionBundle.all)
    func theSandboxCanReadExactlyTheBridgeFolder(_ bundle: ExtensionBundle) throws {
        let entitlements = try plist("Support/Extensions/\(bundle.folder)/\(bundle.folder).entitlements")
        #expect(entitlements["com.apple.security.app-sandbox"] as? Bool == true)
        let readable = entitlements["com.apple.security.temporary-exception.files.home-relative-path.read-only"] as? [String]
        let expected = BridgeLocation.directory(inSupport: URL(fileURLWithPath: "/Library/Application Support/HSpace")).path + "/"
        #expect(readable == [expected])
        #expect(entitlements.count == 2, "only the sandbox and the read exception")
    }

    @Test(arguments: ExtensionBundle.all)
    func everyStringTheExtensionShowsExists(_ bundle: ExtensionBundle) throws {
        let table = try #require(NSDictionary(contentsOf: repository.appendingPathComponent("Resources/en.lproj/Localizable.strings")))
        let keys = try source(bundle).matches(of: /text\("([a-zA-Z.]+)"\)/).map { String($0.output.1) }
        #expect(!keys.isEmpty)
        for key in keys { #expect(table[key] != nil, "\(key)") }
    }
}
