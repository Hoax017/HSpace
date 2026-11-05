import CoreGraphics
import Foundation
import HSpaceTestSupport
import ImageConvert
import ImageIO
import Testing
import UniformTypeIdentifiers

private func picture(width: Int, height: Int, alpha: Bool = false, noise: Bool = false) -> CGImage {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    if alpha {
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
    } else {
        context.setFillColor(CGColor(red: 0.8, green: 0.2, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    }
    if noise, let pixels = context.data {
        arc4random_buf(pixels, context.bytesPerRow * height)
    }
    return context.makeImage()!
}

private func write(_ images: [CGImage], to url: URL, type: UTType = .png, properties: [CFString: Any] = [:]) throws {
    let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, images.count, nil))
    for image in images { CGImageDestinationAddImage(destination, image, properties as CFDictionary) }
    try #require(CGImageDestinationFinalize(destination))
}

private func convert(_ sources: [URL], _ options: ImageConvertOptions) async throws -> [ImageConvertOutcome] {
    var outcomes: [ImageConvertOutcome] = []
    for try await event in ImageConverter.convert(sources, options: options) {
        if case .finished(let outcome) = event { outcomes.append(outcome) }
    }
    return outcomes
}

private struct Info {
    let width: Int, height: Int, frames: Int, type: String, properties: [CFString: Any]
    init(_ url: URL) throws {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        frames = CGImageSourceGetCount(source)
        type = CGImageSourceGetType(source) as String? ?? ""
    }
}

private func fileNames(_ dir: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
}

@Suite struct ConversionTests {
    @Test func aPNGBecomesAJPEGNextToItsSource() async throws {
        let dir = try FaultFixture.tempDir("hspace-image")
        defer { FaultFixture.remove(dir) }
        let source = dir.appendingPathComponent("a.png")
        try write([picture(width: 40, height: 20)], to: source)
        let output = try await convert([source], ImageConvertOptions(format: .jpeg))[0].result.get()
        #expect(output == dir.appendingPathComponent("a.jpg"))
        let info = try Info(output)
        #expect(info.type == UTType.jpeg.identifier)
        #expect(info.width == 40 && info.height == 20)
        #expect(try fileNames(dir) == ["a.jpg", "a.png"])
    }

    @Test func everyWritableFormatRoundTrips() async throws {
        let dir = try FaultFixture.tempDir("hspace-image")
        defer { FaultFixture.remove(dir) }
        let source = dir.appendingPathComponent("a.png")
        try write([picture(width: 32, height: 32)], to: source)
        for format in ImageFormat.allCases where format.isWritable {
            let output = try await convert([source], ImageConvertOptions(format: format))[0].result.get()
            #expect(try Info(output).width == 32, "\(format)")
            #expect(output.pathExtension == format.fileExtension)
        }
    }

    @Test func resizingKeepsTheShapeAndNeverScalesUp() async throws {
        let dir = try FaultFixture.tempDir("hspace-image")
        defer { FaultFixture.remove(dir) }
        let source = dir.appendingPathComponent("a.png")
        try write([picture(width: 400, height: 200)], to: source)
        let half = try await convert([source], ImageConvertOptions(resize: .percent(50)))[0].result.get()
        #expect(try Info(half).width == 200 && Info(half).height == 100)
        let limited = try await convert([source], ImageConvertOptions(resize: .longestSide(100)))[0].result.get()
        #expect(try Info(limited).width == 100 && Info(limited).height == 50)
        let unchanged = try await convert([source], ImageConvertOptions(resize: .longestSide(9000)))[0].result.get()
        #expect(try Info(unchanged).width == 400)
    }

    @Test func aRotatedPhotoComesOutUpright() async throws {
        let dir = try FaultFixture.tempDir("hspace-image")
        defer { FaultFixture.remove(dir) }
        let source = dir.appendingPathComponent("a.jpg")
        try write([picture(width: 40, height: 20)], to: source, type: .jpeg, properties: [kCGImagePropertyOrientation: 6])
        let output = try await convert([source], ImageConvertOptions(format: .png))[0].result.get()
        let info = try Info(output)
        #expect(info.width == 20 && info.height == 40)
        #expect((info.properties[kCGImagePropertyOrientation] as? Int ?? 1) == 1)
    }

    @Test func transparencyBecomesWhiteInAJPEG() async throws {
        let dir = try FaultFixture.tempDir("hspace-image")
        defer { FaultFixture.remove(dir) }
        let source = dir.appendingPathComponent("a.png")
        try write([picture(width: 8, height: 8, alpha: true)], to: source)
        let output = try await convert([source], ImageConvertOptions(format: .jpeg, quality: 1))[0].result.get()
        let image = try #require(CGImageSourceCreateWithURL(output as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        let bytes = try #require(image.dataProvider?.data as Data?)
        #expect(bytes[0] > 240)
    }

    @Test func metadataIsKeptOrStripped() async throws {
        let dir = try FaultFixture.tempDir("hspace-image")
        defer { FaultFixture.remove(dir) }
        let source = dir.appendingPathComponent("a.jpg")
        let exif: [CFString: Any] = [kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "kept"]]
        try write([picture(width: 16, height: 16)], to: source, type: .jpeg, properties: exif)
        let kept = try await convert([source], ImageConvertOptions(format: .jpeg))[0].result.get()
        let keptExif = try Info(kept).properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        #expect(keptExif?[kCGImagePropertyExifUserComment] as? String == "kept")
        let stripped = try await convert([source], ImageConvertOptions(format: .jpeg, keepMetadata: false))[0].result.get()
        let strippedExif = try Info(stripped).properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        #expect(strippedExif?[kCGImagePropertyExifUserComment] == nil)
    }

    @Test func framesSurviveOnlyWhereTheFormatHoldsThem() async throws {
        let dir = try FaultFixture.tempDir("hspace-image")
        defer { FaultFixture.remove(dir) }
        let source = dir.appendingPathComponent("a.gif")
        let frames = [picture(width: 8, height: 8), picture(width: 8, height: 8, alpha: true)]
        try write(frames, to: source, type: .gif)
        #expect(try Info(source).frames == 2)
        let gif = try await convert([source], ImageConvertOptions(resize: .percent(50)))[0].result.get()
        #expect(try Info(gif).frames == 2)
        #expect(try Info(gif).width == 4)
        let png = try await convert([source], ImageConvertOptions(format: .png))[0].result.get()
        #expect(try Info(png).frames == 1)
    }

    @Test func aDestinationFolderIsHonoured() async throws {
        let dir = try FaultFixture.tempDir("hspace-image")
        defer { FaultFixture.remove(dir) }
        let source = dir.appendingPathComponent("a.png")
        let target = dir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try write([picture(width: 8, height: 8)], to: source)
        let output = try await convert([source], ImageConvertOptions(format: .tiff, destination: target))[0].result.get()
        #expect(output.deletingLastPathComponent().standardizedFileURL == target.standardizedFileURL)
    }
}

@Suite struct OutputSafetyTests {
    @Test func theSourceIsNeverReplaced() async throws {
        let dir = try FaultFixture.tempDir("hspace-image")
        defer { FaultFixture.remove(dir) }
        let source = dir.appendingPathComponent("a.png")
        try write([picture(width: 40, height: 40)], to: source)
        let before = try Data(contentsOf: source)
        let output = try await convert([source], ImageConvertOptions(resize: .percent(50)))[0].result.get()
        #expect(output.lastPathComponent == "a 2.png")
        #expect(try Data(contentsOf: source) == before)
    }

    @Test func existingNamesAndNamesTakenInTheBatchAreRespected() async throws {
        let dir = try FaultFixture.tempDir("hspace-image")
        defer { FaultFixture.remove(dir) }
        let png = dir.appendingPathComponent("a.png"), tiff = dir.appendingPathComponent("a.tiff")
        try write([picture(width: 8, height: 8)], to: png)
        try write([picture(width: 8, height: 8)], to: tiff, type: .tiff)
        try FaultFixture.write(Data("mine".utf8), to: dir.appendingPathComponent("a.jpg"))
        let outcomes = try await convert([png, tiff], ImageConvertOptions(format: .jpeg))
        #expect(try outcomes.map { try $0.result.get().lastPathComponent } == ["a 2.jpg", "a 3.jpg"])
        #expect(try Data(contentsOf: dir.appendingPathComponent("a.jpg")) == Data("mine".utf8))
    }

    @Test func oneBadFileDoesNotStopTheOthers() async throws {
        let dir = try FaultFixture.tempDir("hspace-image")
        defer { FaultFixture.remove(dir) }
        let text = dir.appendingPathComponent("note.txt"), missing = dir.appendingPathComponent("gone.png")
        let good = dir.appendingPathComponent("a.png")
        try FaultFixture.write(to: text)
        try write([picture(width: 8, height: 8)], to: good)
        let outcomes = try await convert([text, missing, good], ImageConvertOptions(format: .jpeg))
        #expect(throws: ImageConvertError.self) { try outcomes[0].result.get() }
        #expect(throws: ImageConvertError.self) { try outcomes[1].result.get() }
        #expect(try outcomes[2].result.get().lastPathComponent == "a.jpg")
    }

    @Test func aReadOnlyFolderIsReportedAndStaysEmpty() async throws {
        let dir = try FaultFixture.tempDir("hspace-image")
        defer { FaultFixture.remove(dir) }
        let source = dir.appendingPathComponent("a.png"), locked = dir.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try write([picture(width: 8, height: 8)], to: source)
        try await FaultFixture.withReadOnly(locked) {
            let outcomes = try await convert([source], ImageConvertOptions(format: .jpeg, destination: locked))
            #expect(throws: ImageConvertError.self) { try outcomes[0].result.get() }
        }
        #expect(try fileNames(locked).isEmpty)
    }

    @Test func aFullDiskFailsAndLeavesNoPartialFile() async throws {
        let dir = try FaultFixture.tempDir("hspace-image")
        defer { FaultFixture.remove(dir) }
        let source = dir.appendingPathComponent("a.png")
        // Noise does not compress, so the PNG is about 4 MB against 1 MB free
        try write([picture(width: 1200, height: 1200, noise: true)], to: source)
        let volume = try ScratchVolume(sizeMB: 16)
        try volume.fill(leaving: 1 << 20)
        let before = try fileNames(volume.url).filter { !$0.hasPrefix(".filler") }
        let outcomes = try await convert([source], ImageConvertOptions(format: .png, destination: volume.url))
        #expect(throws: ImageConvertError.self) { try outcomes[0].result.get() }
        let after = try fileNames(volume.url).filter { !$0.hasPrefix(".filler") }
        #expect(after == before, "\(after) \(before)")
    }

    @Test func anEjectedDestinationIsReported() async throws {
        let dir = try FaultFixture.tempDir("hspace-image")
        defer { FaultFixture.remove(dir) }
        let source = dir.appendingPathComponent("a.png")
        try write([picture(width: 8, height: 8)], to: source)
        let volume = try ScratchVolume()
        let folder = volume.url
        try volume.eject()
        let gone = folder.appendingPathComponent("nested", isDirectory: true)
        let outcomes = try await convert([source], ImageConvertOptions(format: .jpeg, destination: gone))
        #expect(throws: ImageConvertError.self) { try outcomes[0].result.get() }
    }

    @Test func cancellingStopsBeforeTheNextImage() async throws {
        let dir = try FaultFixture.tempDir("hspace-image")
        defer { FaultFixture.remove(dir) }
        let source = dir.appendingPathComponent("a.png")
        try write([picture(width: 2000, height: 2000, noise: true)], to: source)
        let sources = Array(repeating: source, count: 200)
        let cancel = ImageConvertCancel()
        var finished = 0
        for try await event in ImageConverter.convert(sources, options: ImageConvertOptions(format: .png), cancel: cancel) {
            switch event {
            case .progress: cancel.cancel()
            case .finished: finished += 1
            }
        }
        #expect(finished < sources.count)
        // What was reported is what exists, with nothing half-written beside it
        #expect(try fileNames(dir).count == finished + 1)
        #expect(try fileNames(dir).allSatisfy { !$0.hasPrefix(".hspace-image") })
    }
}
