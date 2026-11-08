import Darwin
import Foundation
import HSpaceContracts
import Security

// ExtensionBridge pod's sole public contract surface (Axiom 3): what the app shares with its sandboxed extensions
// (the Finder Sync extension, L60, and the share extension, L61), and the one way they may ask the app for something.
//
// An extension runs in its own sandbox: it cannot reach the app's stores, and the app cannot call into it. So the app
// publishes a small read-only snapshot, and an extension asks for work through an `hspace://stash` link that carries
// the snapshot's secret. A web page can open `hspace://` links too, but cannot read the snapshot, so it cannot forge one.

/// What the app publishes for its extensions
public struct BridgeSnapshot: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    /// Proves a stash link came from something that can read this file
    public var token: String
    /// Paths of the items on the stash shelf, for Finder badges
    public var stashedPaths: [String]

    public init(version: Int = BridgeSnapshot.currentVersion, token: String, stashedPaths: [String]) {
        self.version = version
        self.token = token
        self.stashedPaths = stashedPaths
    }
}

public struct BridgeError: ClassifiedError, LocalizedError, Equatable {
    public let errorClass: ErrorClass
    public let localizedDescription: String
    public var errorDescription: String? { localizedDescription }

    init(_ cls: ErrorClass, _ message: String) {
        errorClass = cls
        localizedDescription = message
    }
}

/// Where the snapshot lives, and how its readers hear about changes
public enum BridgeLocation {
    /// Folder inside the app's support directory. The extensions' sandbox entitlements name this exact folder.
    public static let folderName = "Extensions"
    public static let fileName = "bridge.json"
    /// Posted by the app after each publish. It carries nothing: sandboxed receivers get no user info anyway.
    public static let changedNotification = Notification.Name("com.hoax017.hspace.extensionBridgeChanged")

    public static func directory(inSupport support: URL) -> URL {
        support.appendingPathComponent(folderName, isDirectory: true)
    }

    /// The app's support directory as seen from a sandboxed extension. Inside the sandbox the home directory APIs
    /// answer with the container, so the real home comes from the user database.
    public static func appSupportOutsideSandbox() -> URL {
        let home: String
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir {
            home = String(cString: dir)
        } else {
            home = NSHomeDirectory()
        }
        return URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent("Library/Application Support/HSpace", isDirectory: true)
    }
}

/// Extension side: reads what the app published
public enum BridgeReader {
    /// nil when the app has not published yet. A snapshot from a newer app, or a damaged file, is an error.
    public static func read(from directory: URL) -> Result<BridgeSnapshot?, BridgeError> {
        let url = directory.appendingPathComponent(BridgeLocation.fileName)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            return .success(nil)
        } catch {
            return .failure(BridgeError(.external, "HSpace's extension data could not be read: \(error.localizedDescription)"))
        }
        let snapshot: BridgeSnapshot
        do {
            snapshot = try JSONDecoder().decode(BridgeSnapshot.self, from: data)
        } catch {
            return .failure(BridgeError(.external, "HSpace's extension data is damaged. Open HSpace once to rewrite it."))
        }
        guard snapshot.version == BridgeSnapshot.currentVersion else {
            return .failure(BridgeError(.logic, "HSpace's extension data is from another version. Open HSpace once to rewrite it."))
        }
        return .success(snapshot)
    }
}

/// App side: sole commit owner of the snapshot. The file is a cache of state owned elsewhere (the stash shelf),
/// so a damaged one is simply replaced: nothing in it is the only copy of anything.
public actor BridgePublisher {
    private let directory: URL
    private let makeToken: @Sendable () throws -> String
    private var token: String?

    public init(directory: URL, makeToken: @escaping @Sendable () throws -> String = BridgeToken.random) {
        self.directory = directory
        self.makeToken = makeToken
    }

    /// The secret, read from an earlier snapshot when there is one, so links made before a relaunch still work
    public func currentToken() throws -> String {
        if let token { return token }
        if case .success(let snapshot?) = BridgeReader.read(from: directory), BridgeToken.isWellFormed(snapshot.token) {
            token = snapshot.token
            return snapshot.token
        }
        let fresh: String
        do {
            fresh = try makeToken()
        } catch {
            throw BridgeError(.transient, "Could not make a secret for HSpace's extensions: \(error.localizedDescription)")
        }
        token = fresh
        return fresh
    }

    /// Writes the snapshot atomically, readable by this user only
    public func publish(stashedPaths: [String]) throws {
        let snapshot = BridgeSnapshot(token: try currentToken(), stashedPaths: stashedPaths)
        let url = directory.appendingPathComponent(BridgeLocation.fileName)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            throw BridgeError(.external, "Could not update HSpace's extension data: \(error.localizedDescription)")
        }
    }
}

public enum BridgeToken {
    static let byteCount = 32

    public static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw BridgeError(.transient, "The system random generator failed (\(status)).")
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    public static func isWellFormed(_ token: String) -> Bool {
        token.utf8.count == byteCount * 2 && token.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    /// Compares every byte whatever the first difference, so timing says nothing about how much of a guess was right
    static func matches(_ given: String, _ expected: String) -> Bool {
        let a = Array(given.utf8), b = Array(expected.utf8)
        guard a.count == b.count, !b.isEmpty else { return false }
        var diff: UInt8 = 0
        for i in a.indices { diff |= a[i] ^ b[i] }
        return diff == 0
    }
}

/// Which items Finder should badge
public struct BadgeIndex: Equatable, Sendable {
    public static let stashedBadge = "stashed"
    private let paths: Set<String>

    public init(paths: [String]) {
        self.paths = Set(paths.map(Self.normalize))
    }

    public func badge(forPath path: String) -> String? {
        paths.contains(Self.normalize(path)) ? Self.stashedBadge : nil
    }

    /// Paths whose badge differs between two indexes: the ones Finder must be told about after a change
    public static func changes(from old: BadgeIndex, to new: BadgeIndex) -> Set<String> {
        old.paths.symmetricDifference(new.paths)
    }

    /// Text only, never the disk: Finder asks for every item it draws
    static func normalize(_ path: String) -> String {
        let standard = URL(fileURLWithPath: path).standardizedFileURL.path
        return standard.count > 1 && standard.hasSuffix("/") ? String(standard.dropLast()) : standard
    }
}

public enum StashLinkRejection: Error, Equatable, Sendable {
    /// Not an `hspace://stash` link at all
    case notAStashLink
    /// Missing or wrong secret: the link was not made by an HSpace extension
    case untrusted
    case noItems
    case tooManyItems
    case invalidPath
}

/// `hspace://stash?token=<secret>&path=<p>&path=<p>`: an extension asking the app to stash items
public enum StashLink {
    public static let maxItems = 500

    public static func make(paths: [String], token: String) -> URL? {
        guard !paths.isEmpty, paths.count <= maxItems else { return nil }
        var comps = URLComponents()
        comps.scheme = "hspace"
        comps.host = "stash"
        comps.queryItems = [URLQueryItem(name: "token", value: token)] + paths.map { URLQueryItem(name: "path", value: $0) }
        // `+` is a space to many decoders: encode it so a path holding one comes back unchanged
        comps.percentEncodedQuery = comps.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return comps.url
    }

    public static func isStashLink(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "hspace" && url.host?.lowercased() == "stash"
    }

    /// Checks the link's text only. The app still applies its own local path policy before touching any path.
    public static func parse(_ url: URL, expectedToken: String) -> Result<[String], StashLinkRejection> {
        guard isStashLink(url), let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              comps.user == nil, comps.password == nil, comps.port == nil, comps.path.isEmpty
        else { return .failure(.notAStashLink) }
        let items = comps.queryItems ?? []
        let tokens = items.filter { $0.name == "token" }
        guard tokens.count == 1, let given = tokens[0].value, BridgeToken.matches(given, expectedToken)
        else { return .failure(.untrusted) }
        guard items.allSatisfy({ $0.name == "token" || $0.name == "path" }) else { return .failure(.invalidPath) }
        let paths = items.filter { $0.name == "path" }.map { $0.value ?? "" }
        guard !paths.isEmpty else { return .failure(.noItems) }
        guard paths.count <= maxItems else { return .failure(.tooManyItems) }
        guard paths.allSatisfy({ $0.hasPrefix("/") && !$0.contains("\0") && !$0.split(separator: "/").contains("..") })
        else { return .failure(.invalidPath) }
        return .success(paths)
    }
}

public enum ShareInputRejection: Error, Equatable, Sendable {
    /// Nothing shared was a file: text, web links and images held only in memory cannot go on the shelf
    case noFiles
    case tooManyItems
}

/// Share extension (L61): which of the shared items can go on the stash shelf
public enum ShareInput {
    /// Files only, each once, in the order shared
    public static func paths(from urls: [URL]) -> Result<[String], ShareInputRejection> {
        var seen = Set<String>()
        let paths = urls.filter(\.isFileURL).map(\.standardizedFileURL.path).filter { seen.insert($0).inserted }
        guard !paths.isEmpty else { return .failure(.noFiles) }
        guard paths.count <= StashLink.maxItems else { return .failure(.tooManyItems) }
        return .success(paths)
    }
}
