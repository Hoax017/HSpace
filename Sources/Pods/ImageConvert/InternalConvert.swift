import CoreGraphics
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Private concern: decoding, scaling, encoding and landing the output

private extension ImageFormat {
    var type: UTType {
        switch self {
        case .png: return .png
        case .jpeg: return .jpeg
        case .heic: return .heic
        case .tiff: return .tiff
        case .gif: return .gif
        case .bmp: return .bmp
        }
    }

    var keepsFrames: Bool { self == .gif || self == .tiff }
    var hasNoAlpha: Bool { self == .jpeg || self == .bmp }

    init?(type: UTType) {
        guard let match = ImageFormat.allCases.first(where: { type.conforms(to: $0.type) }) else { return nil }
        self = match
    }
}

func isEncodable(_ format: ImageFormat) -> Bool {
    let writable = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
    return writable.contains(format.type.identifier)
}

private func failure(_ message: String, _ url: URL) -> ImageConvertError {
    ImageConvertError(.external, message, path: url.path)
}

private func pixelSide(of source: CGImageSource, at index: Int) -> Int? {
    guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
          let width = properties[kCGImagePropertyPixelWidth] as? Int,
          let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
    return max(width, height)
}

private func targetSide(from side: Int, resize: ImageResize) -> Int {
    switch resize {
    case .original: return side
    case .percent(let percent): return max(1, side * min(max(percent, 1), 100) / 100)
    case .longestSide(let limit): return min(side, max(limit, 1))
    }
}

/// Pixels come out upright, so every path below can write orientation 1.
private func decode(_ source: CGImageSource, at index: Int, side: Int) -> CGImage? {
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: side,
        kCGImageSourceShouldCacheImmediately: true,
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary)
}

private func frameProperties(of source: CGImageSource, at index: Int, format: ImageFormat,
                             options: ImageConvertOptions) -> [CFString: Any] {
    let original = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
    var properties: [CFString: Any] = options.keepMetadata ? original : [:]
    // Frame timing is part of the picture, not metadata
    if let gif = original[kCGImagePropertyGIFDictionary] { properties[kCGImagePropertyGIFDictionary] = gif }
    properties[kCGImagePropertyOrientation] = 1
    if var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
        tiff[kCGImagePropertyTIFFOrientation] = 1
        properties[kCGImagePropertyTIFFDictionary] = tiff
    }
    for size in [kCGImagePropertyPixelWidth, kCGImagePropertyPixelHeight] { properties[size] = nil }
    properties[kCGImageDestinationLossyCompressionQuality] = min(max(options.quality, 0), 1)
    if format.hasNoAlpha { properties[kCGImageDestinationBackgroundColor] = CGColor(gray: 1, alpha: 1) }
    return properties
}

private func encode(_ source: CGImageSource, format: ImageFormat, options: ImageConvertOptions, sourceURL: URL, to staged: URL) throws {
    let frames = format.keepsFrames ? Array(0..<CGImageSourceGetCount(source)) : [CGImageSourceGetPrimaryImageIndex(source)]
    guard let destination = CGImageDestinationCreateWithURL(staged as CFURL, format.type.identifier as CFString, frames.count, nil) else {
        throw failure("\(staged.deletingLastPathComponent().lastPathComponent) cannot be written to.", sourceURL)
    }
    for index in frames {
        guard let side = pixelSide(of: source, at: index),
              let image = decode(source, at: index, side: targetSide(from: side, resize: options.resize)) else {
            throw failure("\(sourceURL.lastPathComponent) could not be decoded.", sourceURL)
        }
        CGImageDestinationAddImage(destination, image, frameProperties(of: source, at: index, format: format, options: options) as CFDictionary)
    }
    guard CGImageDestinationFinalize(destination) else {
        throw failure("\(sourceURL.lastPathComponent) could not be written. The disk may be full.", sourceURL)
    }
}

/// Moves the finished file to the first free name. Only a rename that refuses an existing target can promise never to replace anything.
private func land(_ staged: URL, stem: String, ext: String, in folder: URL) throws -> URL {
    var number = 1
    while true {
        let name = number == 1 ? "\(stem).\(ext)" : "\(stem) \(number).\(ext)"
        let target = folder.appendingPathComponent(name)
        if renamex_np(staged.path, target.path, UInt32(RENAME_EXCL)) == 0 { return target }
        var code = errno
        if code == ENOTSUP || code == EINVAL {
            // File systems without RENAME_EXCL (exFAT, SMB)
            var info = stat()
            if lstat(target.path, &info) == 0 {
                code = EEXIST
            } else if rename(staged.path, target.path) == 0 {
                return target
            } else {
                code = errno
            }
        }
        guard code == EEXIST else {
            throw failure("Could not write \(name): \(String(cString: strerror(code)))", target)
        }
        number += 1
    }
}

private func convertOne(_ url: URL, options: ImageConvertOptions) throws -> URL {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0,
          let typeID = CGImageSourceGetType(source) as String?, let type = UTType(typeID) else {
        throw failure("\(url.lastPathComponent) is not an image that can be read.", url)
    }
    guard let format = options.format ?? ImageFormat(type: type) else {
        throw failure("\(url.lastPathComponent) cannot be saved in its own format. Choose one.", url)
    }
    guard format.isWritable else {
        throw failure("This Mac cannot write \(format.rawValue.uppercased()) files.", url)
    }
    let folder = options.destination ?? url.deletingLastPathComponent()
    // A folder of its own: ImageIO writes through a temporary file beside its target and leaves it behind when the disk fills up
    let staging = folder.appendingPathComponent(".hspace-image-\(UUID().uuidString)", isDirectory: true)
    do {
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
    } catch {
        throw failure("\(folder.lastPathComponent) cannot be written to: \(error.localizedDescription)", folder)
    }
    defer { try? FileManager.default.removeItem(at: staging) }    // Holds nothing of the user's
    let staged = staging.appendingPathComponent("output")
    try encode(source, format: format, options: options, sourceURL: url, to: staged)
    let keepsExtension = options.format == nil
    return try land(staged, stem: url.deletingPathExtension().lastPathComponent,
                    ext: keepsExtension ? url.pathExtension : format.fileExtension, in: folder)
}

func convertStream(_ sources: [URL], options: ImageConvertOptions,
                   cancel: ImageConvertCancel) -> AsyncThrowingStream<ImageConvertEvent, any Error> {
    AsyncThrowingStream { continuation in
        continuation.onTermination = { _ in cancel.cancel() }
        // A plain thread rather than the cooperative pool: decoding a large image blocks for seconds
        DispatchQueue(label: "com.hoax017.hspace.imageconvert", qos: .userInitiated).async {
            for (index, url) in sources.enumerated() {
                if cancel.isCancelled { break }
                continuation.yield(.progress(done: index, total: sources.count, current: url))
                let result: Result<URL, ImageConvertError> = autoreleasepool {
                    do {
                        return .success(try convertOne(url, options: options))
                    } catch let error as ImageConvertError {
                        return .failure(error)
                    } catch {
                        return .failure(failure(error.localizedDescription, url))
                    }
                }
                continuation.yield(.finished(ImageConvertOutcome(source: url, result: result)))
            }
            continuation.finish()
        }
    }
}
