import Foundation
import HSpaceContracts

// ArchiveEngine pod's sole public contract surface (Axiom 3):
// Archiving: compress / extract, driven via Process through system tools (zip/tar/unzip/gunzip…),
// with no third-party dependencies (the honest approach). Node boundaries follow irreversible side effects: one compress = one archive produced;
// one extract = one content tree landed from an archive; each is one atomic commit unit.
//
// Passwords are refused with a logic error, for every format. zip and unzip take a password only on the command line,
// where other processes can read it, or from a terminal, which this node does not have. tar has no encryption at all.
// An empty password means no password. Password support returns with a way to pass it safely (L53).

public struct ArchiveError: ClassifiedError {
    public let errorClass: ErrorClass
    public let localizedDescription: String
    public let path: String?

    init(_ cls: ErrorClass, _ message: String, path: String? = nil) {
        self.errorClass = cls
        self.localizedDescription = message
        self.path = path
    }
}

// MARK: - Pure logic helpers (black-box unit-testable, no real file system needed)

/// Archive naming (extensionless base name + full suffix): base.ext → "base 2.ext" → "base 3.ext"… (skips existing names).
/// ext is the full suffix without a leading dot (such as "zip" / "tar.gz"); the number is appended only to base, the suffix stays whole.
public func uniqueArchiveName(base: String, ext: String, in directory: URL,
                             exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> String {
    func compose(_ n: Int) -> String {
        let stem = n <= 1 ? base : "\(base) \(n)"
        return ext.isEmpty ? stem : "\(stem).\(ext)"
    }
    var n = 1
    while exists(directory.appendingPathComponent(compose(n))) { n += 1 }
    return compose(n)
}

/// Core criterion of the extraction "wrapper semantics" (pure logic): given all entry paths in an archive, counts distinct top-level entries.
/// Top level > 1 → create a same-named wrapper folder first; == 1 (or 0) → skip the wrapper and extract directly (QSpace semantics).
public func topLevelEntryCount(_ entries: [String]) -> Int {
    var tops = Set<String>()
    for raw in entries {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { continue }
        while s.hasPrefix("./") { s.removeFirst(2) }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let first = s.split(separator: "/").first, !first.isEmpty else { continue }
        tops.insert(String(first))
    }
    return tops.count
}

/// Archive format (selects the extraction tool by extension)
public enum ArchiveFormat: Sendable, Equatable {
    case zip
    case tarGz, tarBz2, tarXz, tar   // tar family (including compressed variants)
    case gzip, bzip2, xz             // single-stream compression (not tar)

    /// Detects by URL extension (multi-part suffixes match first; returns nil when unknown)
    public static func detect(_ url: URL) -> ArchiveFormat? {
        let n = url.lastPathComponent.lowercased()
        if n.hasSuffix(".tar.gz") || n.hasSuffix(".tgz") { return .tarGz }
        if n.hasSuffix(".tar.bz2") || n.hasSuffix(".tbz2") || n.hasSuffix(".tbz") { return .tarBz2 }
        if n.hasSuffix(".tar.xz") || n.hasSuffix(".txz") { return .tarXz }
        if n.hasSuffix(".tar") { return .tar }
        if n.hasSuffix(".zip") { return .zip }
        if n.hasSuffix(".gz") || n.hasSuffix(".z") { return .gzip }   // legacy .Z compress also goes through gunzip
        if n.hasSuffix(".bz2") { return .bzip2 }
        if n.hasSuffix(".xz") { return .xz }
        return nil
    }

    /// Output file name after extracting a single stream (.gz/.bz2/.xz/.Z) = name minus the compression suffix (for wrapper decisions and landing names)
    static func singleStreamOutputName(for url: URL) -> String {
        let name = url.lastPathComponent
        for suffix in [".gz", ".z", ".bz2", ".xz"] where name.lowercased().hasSuffix(suffix) {
            return String(name.dropLast(suffix.count))
        }
        return name
    }
}

// MARK: - Support detection (the honest approach: test the tools actually on the system; extensions without a tool are not listed)

public extension ArchiveEngineNode {
    /// Extensions this machine can extract (built dynamically from tools actually present in /usr/bin; the UI uses this to honestly enable or disable "Extract")
    static func supportedExtensions() -> [String] {
        var exts: [String] = []
        if toolExists(Tools.unzip) { exts += ["zip"] }
        if toolExists(Tools.tar) { exts += ["tar", "tar.gz", "tgz", "tar.bz2", "tbz2", "tbz", "tar.xz", "txz"] }
        if toolExists(Tools.gunzip) { exts += ["gz", "Z"] }
        if toolExists(Tools.bunzip2) { exts += ["bz2"] }
        if toolExists(Tools.xz) { exts += ["xz"] }
        return exts
    }

    /// Whether this URL is an archive this machine can extract (the context menu uses this to decide whether to show "Extract")
    static func isSupportedArchive(_ url: URL) -> Bool {
        guard let fmt = ArchiveFormat.detect(url) else { return false }
        switch fmt {
        case .zip: return toolExists(Tools.unzip)
        case .tarGz, .tarBz2, .tarXz, .tar: return toolExists(Tools.tar)
        case .gzip: return toolExists(Tools.gunzip)
        case .bzip2: return toolExists(Tools.bunzip2)
        case .xz: return toolExists(Tools.xz)
        }
    }

    static func toolExists(_ path: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: path)
    }
}

// MARK: - Browsing without extracting

/// One item of an archive, as its listing describes it. Everything here comes from the archive, so it is untrusted.
public struct ArchiveEntry: Sendable, Hashable {
    public enum Kind: Sendable, Hashable { case file, directory, link }

    /// Relative, "/"-separated path, without "./". Names can hold any bytes: show `ArchiveTreeNode.name` instead.
    public let path: String
    public let kind: Kind
    /// nil when the format does not say (a .gz has no listing)
    public let size: Int64?
    public let modified: Date?
    /// False for an absolute path or one with "..": such an entry is shown and never extracted.
    public let isSafe: Bool
    /// The name in the archive, byte for byte. Legacy zips hold names that are not UTF-8.
    let rawPath: [UInt8]
}

/// A folder or item of an archive. Folders that have no entry of their own are made up from the paths under them.
/// Built once and only read afterwards.
public final class ArchiveTreeNode: @unchecked Sendable {
    /// Last path component, safe to show: control and text-direction characters are replaced
    public let name: String
    public internal(set) var entry: ArchiveEntry
    /// Folders first, then by name as Finder sorts
    public internal(set) var children: [ArchiveTreeNode] = []
    public var isFolder: Bool { entry.kind == .directory }

    init(name: String, entry: ArchiveEntry) {
        self.name = name
        self.entry = entry
    }
}

/// Turns the output of `tar -tvf` into entries. `now` settles the year of recent dates, which tar leaves out.
/// Throws external on a line that is not a listing line, so that a misread listing is never shown as the truth.
public func parseArchiveListing(_ listing: Data, now: Date = Date()) throws -> [ArchiveEntry] {
    try ArchiveListingParser(now: now).parse(listing)
}

/// The tree of a listing. Duplicate paths collapse to the last entry, the one that extraction leaves on disk.
public func archiveTree(_ entries: [ArchiveEntry]) -> ArchiveTreeNode {
    ArchiveTreeBuilder().build(entries)
}

public extension ArchiveEngineNode {
    /// Whether `list` can read this file
    static func isBrowsable(_ url: URL) -> Bool {
        guard let format = ArchiveFormat.detect(url) else { return false }
        switch format {
        case .gzip, .bzip2, .xz: return isSupportedArchive(url)
        default: return toolExists(Tools.tar)
        }
    }

    /// Lists an archive without extracting anything. Cancelling the task stops the tool.
    func list(_ archive: URL) async throws -> [ArchiveEntry] {
        try await listEntries(archive)
    }

    /// Extracts `entries` into `directory`, keeping their paths below it, and returns where each one landed.
    /// A folder comes with everything under it. An unsafe entry is refused before anything runs.
    func extract(_ entries: [ArchiveEntry], from archive: URL, into directory: URL) async throws -> [URL] {
        try await extractEntries(entries, from: archive, into: directory)
    }

    /// A new private folder (0700) in the temporary directory, for what is taken out of an archive
    static func makeScratchDirectory() throws -> URL {
        try createScratchDirectory()
    }

    /// Removes a scratch folder, including read-only folders that an archive may have created in it.
    static func discardScratchDirectory(_ url: URL) throws {
        try removeScratchDirectory(url)
    }
}

/// Absolute system tool paths (the honest approach: fixed /usr/bin, missing tools report external)
enum Tools {
    static let zip = "/usr/bin/zip"
    static let unzip = "/usr/bin/unzip"
    static let tar = "/usr/bin/tar"
    static let gunzip = "/usr/bin/gunzip"
    static let bunzip2 = "/usr/bin/bunzip2"
    static let xz = "/usr/bin/xz"
}
