import Foundation
import CoreGraphics

// IconThumb pod's sole public contract surface (Axiom 3): file URL + size → CGImage thumbnail (purely derived cache).
// The contract returns only CGImage (Sendable), never NSImage: safe to pass across concurrency in the decoration layer, and keeps AppKit out of the engine.

public protocol IconThumbnailing: Sendable {
    /// Generates a thumbnail for url (QuickLook). Any failure returns nil (BG-7: decoration failure must not hurt the main path).
    /// - Parameter size: target size in points (square upper bound); pixels are generated at scale=2, so pixel dimensions are <= size*2.
    /// LRU cache hits return directly; cancellable with the caller's Task (cancelled returns nil).
    func thumbnail(for url: URL, size: CGFloat) async -> CGImage?
}
