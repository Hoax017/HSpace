import AVFoundation
import CoreGraphics
import Foundation
import HSpaceContracts
import ImageIO
import UniformTypeIdentifiers

public struct FileInspector: FileInspecting {
    public init() {}

    public func inspect(_ url: URL) async throws -> InspectorFacts {
        let plain = URL(fileURLWithPath: url.path)
        let base = try await Task.detached(priority: .userInitiated) { () throws -> BaseFacts in
            try Task.checkCancellation()
            return try BaseFacts(plain)
        }.value
        try Task.checkCancellation()
        let media = base.isMedia ? await Self.mediaFacts(plain) : nil
        try Task.checkCancellation()
        return base.facts(url: plain, media: media)
    }

    private static func mediaFacts(_ url: URL) async -> MediaFacts? {
        let asset = AVURLAsset(url: url)
        // Display only: a file AVFoundation refuses still has its other facts
        guard let time = try? await asset.load(.duration) else { return nil }
        var size: CGSize?
        if let track = try? await asset.loadTracks(withMediaType: .video).first {
            size = try? await track.load(.naturalSize)
        }
        let seconds = time.seconds
        return MediaFacts(duration: seconds.isFinite ? seconds : nil,
                          videoWidth: size.map { Int($0.width) }, videoHeight: size.map { Int($0.height) })
    }
}

/// Everything readable without leaving the blocking world
private struct BaseFacts: Sendable {
    let name: String
    let values: URLResourceValuesBox
    let isSymlink: Bool
    let linkTarget: String?
    let linkIsBroken: Bool
    let permissions: UInt16?
    let owner: String?
    let group: String?
    let isLocked: Bool
    let childCount: Int?
    let image: ImageFacts?
    let pageCount: Int?
    let type: UTType?

    var isMedia: Bool { type?.conforms(to: .audiovisualContent) == true && !isSymlink }

    init(_ url: URL) throws {
        let fm = FileManager.default
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try fm.attributesOfItem(atPath: url.path)
        } catch CocoaError.fileReadNoSuchFile, CocoaError.fileNoSuchFile {
            throw InspectorError(.external, "\"\(url.lastPathComponent)\" is no longer there.")
        } catch {
            throw InspectorError(.external, "Could not read \"\(url.lastPathComponent)\": \(error.localizedDescription)")
        }
        name = url.lastPathComponent
        isSymlink = attributes[.type] as? FileAttributeType == .typeSymbolicLink
        permissions = (attributes[.posixPermissions] as? NSNumber).map { UInt16(truncatingIfNeeded: $0.intValue) }
        owner = attributes[.ownerAccountName] as? String
        group = attributes[.groupOwnerAccountName] as? String
        isLocked = attributes[.immutable] as? Bool ?? false
        if isSymlink {
            linkTarget = try? fm.destinationOfSymbolicLink(atPath: url.path)
            linkIsBroken = !fm.fileExists(atPath: url.path)
        } else {
            linkTarget = nil
            linkIsBroken = false
        }
        let keys: Set<URLResourceKey> = [
            .contentTypeKey, .isDirectoryKey, .isPackageKey, .isHiddenKey, .fileSizeKey, .totalFileAllocatedSizeKey,
            .creationDateKey, .contentModificationDateKey, .contentAccessDateKey, .addedToDirectoryDateKey,
        ]
        let read = try? url.resourceValues(forKeys: keys)
        values = URLResourceValuesBox(read)
        type = read?.contentType
        let isFolder = read?.isDirectory == true && !isSymlink
        childCount = isFolder && read?.isPackage != true ? (try? fm.contentsOfDirectory(atPath: url.path).count) : nil
        image = !isSymlink && type?.conforms(to: .image) == true ? Self.imageFacts(url) : nil
        pageCount = !isSymlink && type?.conforms(to: .pdf) == true
            ? CGPDFDocument(url as CFURL).map { $0.numberOfPages } : nil
    }

    func facts(url: URL, media: MediaFacts?) -> InspectorFacts {
        InspectorFacts(url: url, name: name, typeID: type?.identifier,
                       isDirectory: values.isDirectory, isPackage: values.isPackage, isSymlink: isSymlink,
                       linkTarget: linkTarget, linkIsBroken: linkIsBroken,
                       logicalSize: values.isDirectory ? nil : values.fileSize,
                       allocatedSize: values.isDirectory ? nil : values.allocatedSize,
                       created: values.created, modified: values.modified, accessed: values.accessed, added: values.added,
                       permissions: permissions, owner: owner, group: group, isLocked: isLocked, isHidden: values.isHidden,
                       childCount: childCount, image: image, media: media, pageCount: pageCount)
    }

    private static func imageFacts(_ url: URL) -> ImageFacts? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
              let raw = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
              let width = raw[kCGImagePropertyPixelWidth] as? Int,
              let height = raw[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return ImageFacts(pixelWidth: width, pixelHeight: height, dpi: raw[kCGImagePropertyDPIWidth] as? Double,
                          colorModel: raw[kCGImagePropertyColorModel] as? String,
                          hasAlpha: raw[kCGImagePropertyHasAlpha] as? Bool)
    }
}

/// `URLResourceValues` is not Sendable, so the values are copied out
private struct URLResourceValuesBox: Sendable {
    let isDirectory: Bool
    let isPackage: Bool
    let isHidden: Bool
    let fileSize: Int64?
    let allocatedSize: Int64?
    let created: Date?
    let modified: Date?
    let accessed: Date?
    let added: Date?

    init(_ read: URLResourceValues?) {
        isDirectory = read?.isDirectory ?? false
        isPackage = read?.isPackage ?? false
        isHidden = read?.isHidden ?? false
        fileSize = read?.fileSize.map(Int64.init)
        allocatedSize = read?.totalFileAllocatedSize.map(Int64.init)
        created = read?.creationDate
        modified = read?.contentModificationDate
        accessed = read?.contentAccessDate
        added = read?.addedToDirectoryDate
    }
}
