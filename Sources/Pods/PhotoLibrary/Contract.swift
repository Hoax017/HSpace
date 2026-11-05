import CoreGraphics
import Foundation
import HSpaceContracts

// PhotoLibrary pod's sole public contract surface (Axiom 3): reading the system Photos library, and copying originals out of it.
// The library itself is never changed. `PhotoLibraryProviding` is the seam: the app uses `SystemPhotoLibrary`, tests a stand-in.

public enum PhotoAccess: Sendable, Equatable {
    case notDetermined
    case granted
    /// The owner chose which photos to share
    case limited
    case denied
    /// Blocked by a device policy, which the owner may not be able to change
    case restricted
}

public struct PhotoCollection: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable { case allPhotos, favorites, videos, album }

    public let id: String
    public let title: String
    public let kind: Kind

    public init(id: String, title: String, kind: Kind) {
        self.id = id
        self.title = title
        self.kind = kind
    }
}

public struct PhotoAsset: Sendable, Hashable, Identifiable {
    public let id: String
    public let isVideo: Bool
    public let created: Date?
    public let pixelWidth: Int
    public let pixelHeight: Int
    /// Seconds. 0 for a photo.
    public let duration: Double

    public init(id: String, isVideo: Bool, created: Date?, pixelWidth: Int, pixelHeight: Int, duration: Double = 0) {
        self.id = id
        self.isVideo = isVideo
        self.created = created
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.duration = duration
    }
}

public struct PhotoLibraryError: ClassifiedError, LocalizedError {
    public let errorClass: ErrorClass
    public let localizedDescription: String
    public var errorDescription: String? { localizedDescription }

    public init(_ cls: ErrorClass, _ message: String) {
        self.errorClass = cls
        self.localizedDescription = message
    }
}

public protocol PhotoLibraryProviding: Sendable {
    func access() -> PhotoAccess
    /// Asks the owner, the first time. Afterwards it only reports.
    func requestAccess() async -> PhotoAccess
    func collections() async throws -> [PhotoCollection]
    /// Newest first. Cancellation throws CancellationError.
    func assets(in collection: PhotoCollection) async throws -> [PhotoAsset]
    /// nil when there is none. Local data only, so that scrolling never downloads.
    func thumbnail(of asset: PhotoAsset, side: CGFloat) async -> CGImage?
    /// The name the file had when it entered the library
    func originalFilename(of asset: PhotoAsset) async throws -> String
    /// Writes the original to a new file at `url`, downloading it from iCloud if needed.
    /// May leave a partial file on failure or cancellation: the caller owns `url`.
    func writeOriginal(of asset: PhotoAsset, to url: URL) async throws
}

public struct PhotoExportFailure: Sendable, Equatable {
    public let assetID: String
    public let message: String

    public init(assetID: String, message: String) {
        self.assetID = assetID
        self.message = message
    }
}

public struct PhotoExportReport: Sendable, Equatable {
    public var exported: [URL] = []
    public var failures: [PhotoExportFailure] = []
    public var cancelled = false

    public init() {}
}

/// Copies originals into a folder. An existing file is never touched: a taken name gets a number.
/// Each file appears whole or not at all, so a cancel or a full disk leaves only what finished.
public struct PhotoExporter: Sendable {
    private let library: any PhotoLibraryProviding

    public init(library: any PhotoLibraryProviding) {
        self.library = library
    }

    /// `progress` gets (finished, total) after each item
    public func export(_ assets: [PhotoAsset], to directory: URL,
                       progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }) async -> PhotoExportReport {
        var report = PhotoExportReport()
        for (index, asset) in assets.enumerated() {
            if Task.isCancelled {
                report.cancelled = true
                return report
            }
            do {
                report.exported.append(try await exportOne(asset, to: directory))
            } catch is CancellationError {
                report.cancelled = true
                return report
            } catch {
                report.failures.append(PhotoExportFailure(assetID: asset.id, message: error.localizedDescription))
            }
            progress(index + 1, assets.count)
        }
        return report
    }

    private func exportOne(_ asset: PhotoAsset, to directory: URL) async throws -> URL {
        let name = Self.usableName(try await library.originalFilename(of: asset))
        let partial = directory.appendingPathComponent(".hspace-partial-\(UUID().uuidString)")
        let fm = FileManager.default
        do {
            try await library.writeOriginal(of: asset, to: partial)
            try Task.checkCancellation()
            return try Self.moveIntoPlace(partial, named: name, in: directory, using: fm)
        } catch {
            if fm.fileExists(atPath: partial.path) {
                do {
                    try fm.removeItem(at: partial)
                } catch let cleanup {
                    throw PhotoLibraryError(.external, "\(error.localizedDescription) A partial file stayed at \(partial.path): \(cleanup.localizedDescription)")
                }
            }
            throw error
        }
    }

    /// `moveItem` refuses a taken name, so two exports racing for one name cannot overwrite each other
    private static func moveIntoPlace(_ partial: URL, named name: String, in directory: URL, using fm: FileManager) throws -> URL {
        var number = 1
        while true {
            let target = directory.appendingPathComponent(numbered(name, number))
            do {
                try fm.moveItem(at: partial, to: target)
                return target
            } catch CocoaError.fileWriteFileExists {
                number += 1
            }
        }
    }

    static func numbered(_ name: String, _ number: Int) -> String {
        guard number > 1 else { return name }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        return ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)"
    }

    /// A library name is only a suggestion: it must stay one name inside the target folder
    static func usableName(_ name: String) -> String {
        let flat = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\0", with: "").trimmingCharacters(in: .whitespaces)
        return flat.isEmpty || flat == "." || flat == ".." ? "Photo" : flat
    }
}
