import AppKit
import Foundation
import HSpaceContracts
import Photos

/// The real library, through PhotoKit. PhotoKit objects are not Sendable, so each call finds its asset again by id.
/// Needs NSPhotoLibraryUsageDescription in the app's Info.plist: without it, asking for access ends the process.
public struct SystemPhotoLibrary: PhotoLibraryProviding {
    public init() {}

    public func access() -> PhotoAccess {
        Self.access(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    public func requestAccess() async -> PhotoAccess {
        Self.access(await PHPhotoLibrary.requestAuthorization(for: .readWrite))
    }

    private static func access(_ status: PHAuthorizationStatus) -> PhotoAccess {
        switch status {
        case .notDetermined: .notDetermined
        case .authorized: .granted
        case .limited: .limited
        case .restricted: .restricted
        case .denied: .denied
        @unknown default: .denied
        }
    }

    public func collections() async throws -> [PhotoCollection] {
        try await Task.detached(priority: .userInitiated) {
            var found = [PhotoCollection(id: "all", title: "All Photos", kind: .allPhotos)]
            let smart = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .smartAlbumFavorites, options: nil)
            smart.enumerateObjects { album, _, _ in
                found.append(PhotoCollection(id: album.localIdentifier, title: album.localizedTitle ?? "Favorites", kind: .favorites))
            }
            let videos = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .smartAlbumVideos, options: nil)
            videos.enumerateObjects { album, _, _ in
                found.append(PhotoCollection(id: album.localIdentifier, title: album.localizedTitle ?? "Videos", kind: .videos))
            }
            let albums = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
            albums.enumerateObjects { album, _, _ in
                found.append(PhotoCollection(id: album.localIdentifier, title: album.localizedTitle ?? "Album", kind: .album))
            }
            try Task.checkCancellation()
            return found
        }.value
    }

    public func assets(in collection: PhotoCollection) async throws -> [PhotoAsset] {
        let task = Task.detached(priority: .userInitiated) { () throws -> [PhotoAsset] in
            let options = PHFetchOptions()
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            let fetched: PHFetchResult<PHAsset>
            if collection.kind == .allPhotos {
                fetched = PHAsset.fetchAssets(with: options)
            } else {
                guard let album = PHAssetCollection.fetchAssetCollections(
                    withLocalIdentifiers: [collection.id], options: nil).firstObject else {
                    throw PhotoLibraryError(.external, "The album \"\(collection.title)\" is no longer in the library.")
                }
                fetched = PHAsset.fetchAssets(in: album, options: options)
            }
            var assets: [PhotoAsset] = []
            assets.reserveCapacity(fetched.count)
            var cancelled = false
            fetched.enumerateObjects { asset, _, stop in
                if Task.isCancelled {
                    cancelled = true
                    stop.pointee = true
                    return
                }
                assets.append(PhotoAsset(id: asset.localIdentifier, isVideo: asset.mediaType == .video,
                                         created: asset.creationDate, pixelWidth: asset.pixelWidth,
                                         pixelHeight: asset.pixelHeight, duration: asset.duration))
            }
            if cancelled { throw CancellationError() }
            return assets
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    private static func find(_ asset: PhotoAsset) throws -> PHAsset {
        guard let found = PHAsset.fetchAssets(withLocalIdentifiers: [asset.id], options: nil).firstObject else {
            throw PhotoLibraryError(.external, "This item is no longer in the library.")
        }
        return found
    }

    public func thumbnail(of asset: PhotoAsset, side: CGFloat) async -> CGImage? {
        guard let found = try? Self.find(asset) else { return nil }
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat   // One callback, so the continuation resumes exactly once
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = false
        let manager = PHImageManager.default()
        let request = RequestID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (done: CheckedContinuation<SendableImage, Never>) in
                request.set(manager.requestImage(for: found, targetSize: CGSize(width: side, height: side), contentMode: .aspectFill,
                                                 options: options) { image, _ in
                    done.resume(returning: SendableImage(image?.cgImage(forProposedRect: nil, context: nil, hints: nil)))
                })
            }.image
        } onCancel: {
            manager.cancelImageRequest(request.value)
        }
    }

    private static func original(of asset: PHAsset) throws -> PHAssetResource {
        let resources = PHAssetResource.assetResources(for: asset)
        let wanted: [PHAssetResourceType] = asset.mediaType == .video ? [.video, .fullSizeVideo] : [.photo, .fullSizePhoto]
        guard let resource = resources.first(where: { wanted.contains($0.type) }) ?? resources.first else {
            throw PhotoLibraryError(.external, "This item has no file to copy.")
        }
        return resource
    }

    public func originalFilename(of asset: PhotoAsset) async throws -> String {
        try Self.original(of: try Self.find(asset)).originalFilename
    }

    public func writeOriginal(of asset: PhotoAsset, to url: URL) async throws {
        let resource = try Self.original(of: try Self.find(asset))
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw PhotoLibraryError(.external, "Could not create a file in \(url.deletingLastPathComponent().path).")
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        let writer = ChunkWriter(handle)
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        let manager = PHAssetResourceManager.default()
        let request = ResourceRequestID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, any Error>) in
                request.set(manager.requestData(for: resource, options: options, dataReceivedHandler: { writer.append($0) }) { error in
                    if let failure = error ?? writer.failure {
                        done.resume(throwing: failure)
                    } else {
                        done.resume()
                    }
                })
            }
        } onCancel: {
            manager.cancelDataRequest(request.value)
        }
    }
}

/// PhotoKit calls back in order, one chunk at a time
private final class ChunkWriter: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()
    private var firstFailure: (any Error)?

    init(_ handle: FileHandle) { self.handle = handle }

    var failure: (any Error)? {
        lock.lock()
        defer { lock.unlock() }
        return firstFailure
    }

    func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard firstFailure == nil else { return }
        do {
            try handle.write(contentsOf: data)
        } catch {
            firstFailure = error
        }
    }
}

private struct SendableImage: @unchecked Sendable {
    let image: CGImage?
    init(_ image: CGImage?) { self.image = image }
}

/// Carries a request id from the start of a request to its cancel handler
private final class RequestID: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = PHInvalidImageRequestID
    var value: PHImageRequestID {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
    func set(_ id: PHImageRequestID) {
        lock.lock()
        defer { lock.unlock() }
        stored = id
    }
}

private final class ResourceRequestID: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: PHAssetResourceDataRequestID = 0
    var value: PHAssetResourceDataRequestID {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
    func set(_ id: PHAssetResourceDataRequestID) {
        lock.lock()
        defer { lock.unlock() }
        stored = id
    }
}
