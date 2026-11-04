import Testing
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import IconThumb

/// Black-box acceptance: only through the Contract public surface + a real temp PNG (generated with ImageIO, no AppKit/NSImage).
@Suite struct IconThumbTests {

    /// Writes a solid-color PNG with CoreGraphics + ImageIO and returns its URL.
    private func makePNG(width: Int, height: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nspace-it-\(UUID().uuidString).png")
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw CocoaError(.fileWriteUnknown)
        }
        ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.85, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
        return url
    }

    @Test func generatesThumbnailWithinRequestedPixelBounds() async throws {
        let png = try makePNG(width: 512, height: 512)
        defer { try? FileManager.default.removeItem(at: png) }

        let size: CGFloat = 128
        let scale: CGFloat = 2
        let thumb = await IconThumb().thumbnail(for: png, size: size)

        let image = try #require(thumb, "A real PNG should produce a thumbnail")
        #expect(image.width > 0 && image.height > 0)
        #expect(image.width <= Int(size * scale))
        #expect(image.height <= Int(size * scale))
    }

    @Test func returnsNilForMissingFile() async {
        let bogus = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString).png")
        let thumb = await IconThumb().thumbnail(for: bogus, size: 128)
        #expect(thumb == nil)
    }

    @Test func secondRequestReturnsCachedImage() async throws {
        let png = try makePNG(width: 256, height: 256)
        defer { try? FileManager.default.removeItem(at: png) }

        let icon = IconThumb()
        let first = await icon.thumbnail(for: png, size: 96)
        let second = await icon.thumbnail(for: png, size: 96)
        #expect(first != nil)
        // A cache hit should return the same CGImage instance (reference equality)
        #expect(first === second)
    }
}
