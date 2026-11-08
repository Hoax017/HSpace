import Foundation

// ServiceRequests pod's sole public contract surface (Axiom 3): what each HSpace entry in the system Services menu (L63)
// accepts, checked before the app opens a tool on it. Services hand over whatever the other app had selected.

/// HSpace's entries in the Services menu, besides "Open in HSpace"
public enum HSpaceService: String, CaseIterable, Sendable {
    case showHashes, batchRename, addToStash

    /// The provider method named by NSMessage in Info.plist, without the `:userData:error:` part
    public var message: String {
        switch self {
        case .showHashes: "showHashesInHSpace"
        case .batchRename: "batchRenameInHSpace"
        case .addToStash: "addToHSpaceStash"
        }
    }
}

public enum ServiceRejection: Error, Equatable, Sendable {
    /// Nothing given was a file or folder on this Mac
    case nothingUsable
    /// Hashes are for files: only folders were given
    case onlyFolders
    /// An item went away between the selection and the request
    case missing(String)
}

/// One item a service will act on, with what the tools need to know about it
public struct ServiceItem: Equatable, Sendable {
    public let url: URL
    public let isDirectory: Bool
    public let isPackage: Bool
    public let created: Date?
    public let modified: Date?

    public init(url: URL, isDirectory: Bool, isPackage: Bool, created: Date?, modified: Date?) {
        self.url = url
        self.isDirectory = isDirectory
        self.isPackage = isPackage
        self.created = created
        self.modified = modified
    }
}

public enum ServicePlan {
    /// The items `service` acts on, in the order given and each once. Reads the disk for each item.
    public static func items(for service: HSpaceService, from urls: [URL]) -> Result<[ServiceItem], ServiceRejection> {
        var seen = Set<String>()
        let files = urls.filter { $0.isFileURL && $0.path.hasPrefix("/") }
            .map(\.standardizedFileURL)
            .filter { seen.insert($0.path).inserted }
        guard !files.isEmpty else { return .failure(.nothingUsable) }
        var items: [ServiceItem] = []
        for url in files {
            let values: URLResourceValues
            do {
                values = try url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .creationDateKey, .contentModificationDateKey])
            } catch {
                return .failure(.missing(url.lastPathComponent))
            }
            items.append(ServiceItem(url: url, isDirectory: values.isDirectory ?? false, isPackage: values.isPackage ?? false,
                                     created: values.creationDate, modified: values.contentModificationDate))
        }
        guard service == .showHashes else { return .success(items) }
        // A hash reads one file's bytes; a folder has none of its own
        let hashable = items.filter { !$0.isDirectory }
        return hashable.isEmpty ? .failure(.onlyFolders) : .success(hashable)
    }
}
