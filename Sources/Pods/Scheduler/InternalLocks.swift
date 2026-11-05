import Darwin
import Foundation

/// Path spelling used for locks: real location, whatever links led to it, and without regard to case, since the
/// default APFS treats those names as one item. Two different paths folded together wait for each other, which is safe.
enum LockPath {
    static func key(_ url: URL) -> String {
        real(url.standardizedFileURL.path).precomposedStringWithCanonicalMapping.lowercased()
    }

    /// realpath of the deepest part that exists: a destination may not exist yet.
    private static func real(_ path: String) -> String {
        var existing = path
        var missing: [String] = []
        while existing != "/", !existing.isEmpty {
            if let resolved = realpath(existing, nil) {
                defer { free(resolved) }
                return ([String(cString: resolved)] + missing.reversed()).joined(separator: "/")
            }
            missing.append((existing as NSString).lastPathComponent)
            existing = (existing as NSString).deletingLastPathComponent
        }
        return "/" + missing.reversed().joined(separator: "/")
    }

    /// Every folder above the path, nearest first
    static func ancestors(of key: String) -> [String] {
        var result: [String] = []
        var rest = Substring(key)
        while let slash = rest.lastIndex(of: "/") {
            rest = rest[..<slash]
            result.append(rest.isEmpty ? "/" : String(rest))
        }
        return result
    }
}

/// Held claims, indexed so that a check costs the depth of the path and not the number of paths held.
struct LockTable {
    private var reads: Set<String> = []
    private var writes: Set<String> = []
    private var aboveReads: Set<String> = []
    private var aboveWrites: Set<String> = []

    mutating func add(_ claims: PathClaims) {
        for path in claims.reads where reads.insert(path).inserted {
            aboveReads.formUnion(LockPath.ancestors(of: path))
        }
        for path in claims.writes where writes.insert(path).inserted {
            aboveWrites.formUnion(LockPath.ancestors(of: path))
        }
    }

    func conflicts(with claims: PathClaims) -> Bool {
        claims.writes.contains { overlapsRead($0) || overlapsWrite($0) } || claims.reads.contains(where: overlapsWrite)
    }

    private func overlapsWrite(_ path: String) -> Bool {
        writes.contains(path) || aboveWrites.contains(path) || LockPath.ancestors(of: path).contains(where: writes.contains)
    }

    private func overlapsRead(_ path: String) -> Bool {
        reads.contains(path) || aboveReads.contains(path) || LockPath.ancestors(of: path).contains(where: reads.contains)
    }
}
