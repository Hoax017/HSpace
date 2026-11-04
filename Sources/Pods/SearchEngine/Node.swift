import Foundation
import HSpaceContracts

/// Focused search engine (Axiom 2: no global mutable state; each search produces an independent session, no interference).
public struct SearchEngine: Sendable {
    public init() {}

    /// Dual-channel search: channel A Spotlight (name/content) + channel B recursive hidden file name scan (includeHidden).
    /// Results are merged and deduped by url and pushed in increments (>= 50 items or 300ms throttle);
    /// stream termination (consumer cancels / stops iterating) stops both channels (NSMetadataQuery.stop + scan Task cancel).
    @MainActor
    public func search(_ request: SearchRequest) -> AsyncStream<[SearchHit]> {
        AsyncStream { continuation in
            let session = SearchSession(request: request, continuation: continuation)
            session.start()
            continuation.onTermination = { _ in session.stop() }
        }
    }
}
