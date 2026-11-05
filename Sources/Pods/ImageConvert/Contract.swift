import Foundation
import HSpaceContracts

// ImageConvert pod's sole public contract surface (Axiom 3): image format conversion and resizing with ImageIO.
// Always writes a new file: a source is never modified, and an existing name is never replaced.

public struct ImageConvertError: ClassifiedError {
    public let errorClass: ErrorClass
    public let localizedDescription: String
    public let path: String?

    init(_ cls: ErrorClass, _ message: String, path: String? = nil) {
        self.errorClass = cls
        self.localizedDescription = message
        self.path = path
    }
}

public enum ImageFormat: String, Sendable, Hashable, CaseIterable {
    case png, jpeg, heic, tiff, gif, bmp

    public var fileExtension: String {
        switch self {
        case .jpeg: return "jpg"
        case .tiff: return "tiff"
        default: return rawValue
        }
    }

    /// Whether this Mac can encode the format. HEIC depends on the hardware.
    public var isWritable: Bool { isEncodable(self) }
}

public enum ImageResize: Sendable, Hashable {
    case original
    /// 1 to 100
    case percent(Int)
    /// The longer side, in pixels
    case longestSide(Int)
}

public struct ImageConvertOptions: Sendable, Hashable {
    /// nil keeps each image's own format
    public var format: ImageFormat?
    /// 0 to 1, for JPEG and HEIC
    public var quality: Double
    /// An image is never scaled up
    public var resize: ImageResize
    /// Keeps EXIF, GPS and similar. Off strips them.
    public var keepMetadata: Bool
    /// nil writes next to each source
    public var destination: URL?

    public init(format: ImageFormat? = nil, quality: Double = 0.85, resize: ImageResize = .original,
                keepMetadata: Bool = true, destination: URL? = nil) {
        self.format = format; self.quality = quality; self.resize = resize
        self.keepMetadata = keepMetadata; self.destination = destination
    }
}

/// One image's result: a failure belongs to that image and does not stop the others.
public struct ImageConvertOutcome: Sendable {
    public let source: URL
    /// The written file
    public let result: Result<URL, ImageConvertError>

    public init(source: URL, result: Result<URL, ImageConvertError>) {
        self.source = source
        self.result = result
    }
}

public enum ImageConvertEvent: Sendable {
    /// Before starting on `current`
    case progress(done: Int, total: Int, current: URL)
    case finished(ImageConvertOutcome)
}

/// Asks a run to stop before its next image. The stream stays open until the image in hand has landed, so the
/// caller learns about every file that was written: leaving the loop early stops the run too, but loses that.
public final class ImageConvertCancel: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

public enum ImageConverter {
    /// Converts in order on its own thread, streaming progress and each outcome.
    /// Finished images stay after a cancel; nothing half-written does.
    public static func convert(_ sources: [URL], options: ImageConvertOptions,
                               cancel: ImageConvertCancel = ImageConvertCancel()) -> AsyncThrowingStream<ImageConvertEvent, any Error> {
        convertStream(sources, options: options, cancel: cancel)
    }
}
