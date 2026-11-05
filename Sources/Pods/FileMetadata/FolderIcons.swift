import AppKit
import HSpaceContracts

/// What a folder should look like. Custom icons are stored the way Finder stores them (a hidden `Icon\r` file and a flag
/// in FinderInfo), so Finder and other apps show them too.
public enum FolderIconSpec: Sendable, Hashable {
    /// The system folder, optionally tinted, optionally with an emoji on it
    case styled(color: FileColor?, emoji: String?)
    /// An emoji alone, without the folder
    case emoji(String)
    /// A picture from a file
    case image(URL)
}

extension FileColor {
    public var systemColor: NSColor {
        switch self {
        case .red: return .systemRed
        case .orange: return .systemOrange
        case .yellow: return .systemYellow
        case .green: return .systemGreen
        case .teal: return .systemTeal
        case .blue: return .systemBlue
        case .purple: return .systemPurple
        case .pink: return .systemPink
        case .gray: return .systemGray
        }
    }
}

public enum FolderIconRenderer {
    private static let side = 512

    /// Picks the emoji out of typed text, or nil when there is none. One emoji only: it has to fit an icon.
    public static func singleEmoji(in text: String) -> String? {
        // Digits, # and * count as emoji in Unicode, but only as the start of a keycap, which has more than one scalar
        text.first { character in
            character.unicodeScalars.contains { $0.properties.isEmoji && ($0.value > 0xFF || character.unicodeScalars.count > 1) }
        }.map(String.init)
    }

    /// PNG of the icon. Also used for the preview in the app.
    public static func render(_ spec: FolderIconSpec) throws -> Data {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw MetadataError(.transient, "Could not draw the icon")
        }
        let canvas = NSRect(x: 0, y: 0, width: side, height: side)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        defer { NSGraphicsContext.restoreGraphicsState() }

        switch spec {
        case .styled(let color, let emoji):
            guard color != nil || emoji != nil else { throw MetadataError(.logic, "A folder style needs a colour or an emoji") }
            NSWorkspace.shared.icon(for: .folder).draw(in: canvas)
            if let color {
                color.systemColor.withAlphaComponent(0.65).setFill()
                canvas.fill(using: .sourceAtop)
            }
            if let emoji {
                try draw(emoji, in: canvas.insetBy(dx: 128, dy: 128).offsetBy(dx: 0, dy: -32))
            }
        case .emoji(let emoji):
            try draw(emoji, in: canvas.insetBy(dx: 32, dy: 32))
        case .image(let url):
            guard let image = NSImage(contentsOf: url), image.size.width > 0, image.size.height > 0 else {
                throw MetadataError(.external, "\"\(url.lastPathComponent)\" could not be read as a picture")
            }
            let scale = min(canvas.width / image.size.width, canvas.height / image.size.height)
            let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
            image.draw(in: NSRect(x: (canvas.width - size.width) / 2, y: (canvas.height - size.height) / 2,
                                  width: size.width, height: size.height))
        }
        context.flushGraphics()
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw MetadataError(.transient, "Could not draw the icon")
        }
        return png
    }

    private static func draw(_ text: String, in box: NSRect) throws {
        guard let emoji = singleEmoji(in: text) else { throw MetadataError(.logic, "This is not an emoji: \(text)") }
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: box.height * 0.8)]
        let string = NSAttributedString(string: emoji, attributes: attributes)
        let size = string.size()
        string.draw(at: NSPoint(x: box.midX - size.width / 2, y: box.midY - size.height / 2))
    }
}

// Private concern: what NSWorkspace does on disk, in terms the batch runner understands.

private let finderInfoCustomIconByte = 8
private let customIconFlag: UInt8 = 0x04

func hasCustomIcon(_ url: URL) throws -> Bool {
    guard let info = try readAttribute("com.apple.FinderInfo", of: url), info.count == 32 else { return false }
    return info[info.startIndex + finderInfoCustomIconByte] & customIconFlag != 0
}

/// The current custom icon as data, nil for the system icon. This is what undo gives back.
func currentFolderIcon(of url: URL) throws -> Data? {
    guard try hasCustomIcon(url) else { return nil }
    return NSWorkspace.shared.icon(forFile: url.path).tiffRepresentation
}

/// `data` nil removes the custom icon. Only folders: a custom icon on a file would add a resource fork to it.
func writeFolderIcon(_ data: Data?, to url: URL) throws {
    let values: URLResourceValues
    do {
        values = try url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
    } catch {
        throw MetadataError(.external, "\"\(url.lastPathComponent)\" is no longer there")
    }
    guard values.isDirectory == true, values.isPackage != true else {
        throw MetadataError(.logic, "\"\(url.lastPathComponent)\" is not a folder")
    }
    let image = data.flatMap(NSImage.init(data:))
    guard data == nil || image != nil else { throw MetadataError(.logic, "Could not read the icon") }
    // NSWorkspace gives no reason. A folder that exists and refuses comes down to its permissions or its volume.
    guard NSWorkspace.shared.setIcon(image, forFile: url.path, options: []) else {
        throw MetadataError(.external, "Could not change the icon of \"\(url.lastPathComponent)\": no permission, or the volume cannot store it")
    }
}
