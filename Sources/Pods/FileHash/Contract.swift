import Foundation
import HSpaceContracts

// FileHash pod's sole public contract surface (Axiom 3): streaming file digests and their comparison. Read-only by construction.

public struct FileHashError: ClassifiedError {
    public let errorClass: ErrorClass
    public let localizedDescription: String
    public let path: String?

    init(_ cls: ErrorClass, _ message: String, path: String? = nil) {
        self.errorClass = cls
        self.localizedDescription = message
        self.path = path
    }
}

public enum HashAlgorithm: String, Sendable, Hashable, Codable, CaseIterable {
    case md5, sha1, sha256

    /// Digest length in hex characters
    var hexLength: Int {
        switch self {
        case .md5: return 32
        case .sha1: return 40
        case .sha256: return 64
        }
    }
}

public struct FileDigest: Sendable, Hashable {
    public let byteCount: Int64
    /// Lowercase hex, per algorithm
    public let values: [HashAlgorithm: String]

    public init(byteCount: Int64, values: [HashAlgorithm: String]) {
        self.byteCount = byteCount
        self.values = values
    }
}

/// One file's result: a failure belongs to that file and does not stop the others.
public struct FileHashOutcome: Sendable {
    public let url: URL
    public let result: Result<FileDigest, FileHashError>

    public init(url: URL, result: Result<FileDigest, FileHashError>) {
        self.url = url
        self.result = result
    }
}

public struct HashProgress: Sendable, Equatable {
    public let filesDone: Int
    public let fileCount: Int
    public let bytesDone: Int64
    public let bytesTotal: Int64
    public let current: URL
}

public enum HashEvent: Sendable {
    case progress(HashProgress)
    case finished(FileHashOutcome)
}

public enum FileHasher {
    /// Hashes `files` in order, on its own thread, and streams progress and each outcome.
    /// Leaving the loop or cancelling its task stops the read within one chunk, and the loop simply ends.
    public static func hash(_ files: [URL], algorithms: Set<HashAlgorithm>) -> AsyncThrowingStream<HashEvent, any Error> {
        hashStream(files, algorithms: algorithms)
    }

    /// Whether `expected`, as pasted from a web page or a checksum file, equals one of the digests. Returns which.
    /// Case and surrounding white space do not matter; the rest must match exactly.
    public static func match(_ expected: String, in digest: FileDigest) -> HashAlgorithm? {
        let wanted = normalized(expected)
        guard !wanted.isEmpty else { return nil }
        return digest.values.first { $0.value == wanted }?.key
    }

    /// Whether text has the shape of a digest we can compute, which picks the algorithm to check it with.
    public static func algorithm(of expected: String) -> HashAlgorithm? {
        let wanted = normalized(expected)
        guard wanted.allSatisfy(\.isHexDigit) else { return nil }
        return HashAlgorithm.allCases.first { $0.hexLength == wanted.count }
    }

    /// Whether all digests agree in every algorithm they share. nil when fewer than two can be compared.
    public static func allIdentical(_ digests: [FileDigest]) -> Bool? {
        guard digests.count > 1, let first = digests.first else { return nil }
        for other in digests.dropFirst() {
            let shared = Set(first.values.keys).intersection(other.values.keys)
            guard !shared.isEmpty else { return nil }
            if first.byteCount != other.byteCount || shared.contains(where: { first.values[$0] != other.values[$0] }) {
                return false
            }
        }
        return true
    }

    private static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
