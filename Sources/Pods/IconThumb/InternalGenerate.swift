import Foundation
import CoreGraphics
import QuickLookThumbnailing

// Private concern: QLThumbnailGenerator bridge.

/// Generates a thumbnail; any failure (unsupported type / missing file / timeout / cancelled) returns nil without throwing.
/// Cooperative cancellation: checks Task.isCancelled on entry, and the system async generation API itself responds to task cancellation by throwing (swallowed into nil by try?).
func generateThumbnail(url: URL, size: CGFloat, scale: CGFloat) async -> CGImage? {
    if Task.isCancelled { return nil }

    let request = QLThumbnailGenerator.Request(
        fileAt: url,
        size: CGSize(width: size, height: size),
        scale: scale,
        representationTypes: .thumbnail)

    let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
    return rep?.cgImage
}
