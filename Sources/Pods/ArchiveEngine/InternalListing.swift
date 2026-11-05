import Foundation
import HSpaceContracts

// Private concern: reading an archive's table of contents through `tar -tvf`, which reads every format tar can open,
// and needs no decompression of the content in formats with a central directory.
// A listing line looks like:
//   -rw-r--r--  0 owner  group      6 Nov  5 09:57 ./a b.txt
//   lrwxr-xr-x  0 owner  group      0 Jan  2  2015 link -> target
// Owner and group can hold spaces, and names can hold anything, so the date is what anchors the line.
// tar escapes what is not printable as \n, \\ or octal, which also keeps one entry on one line.

/// A listing past this size is refused rather than held in memory. It is about 600,000 entries.
private let listingByteLimit = 64 << 20

extension ArchiveEngineNode {
    func listEntries(_ archive: URL) async throws -> [ArchiveEntry] {
        guard FileManager.default.fileExists(atPath: archive.path) else {
            throw ArchiveError(.external, "Archive not found:\(archive.lastPathComponent)", path: archive.path)
        }
        guard let format = ArchiveFormat.detect(archive) else {
            throw ArchiveError(.logic, "Unrecognized archive format:\(archive.lastPathComponent)", path: archive.path)
        }
        switch format {
        case .gzip, .bzip2, .xz:
            // One compressed stream: no names, no listing, and its only item is what the name promises
            return [ArchiveEntry(raw: Array(ArchiveFormat.singleStreamOutputName(for: archive).utf8), kind: .file,
                                 size: nil, modified: nil)]
        default:
            break
        }
        // The archive path is absolute and follows -f, so its name cannot be read as an option
        let result = try await runTool(Tools.tar, ["-tvf", archive.path], captureStdout: listingByteLimit,
                                       utf8Locale: true)
        if Task.isCancelled { throw CancellationError() }
        guard result.status == 0 else {
            let summary = Self.stderrSummary(result.stderr)
            throw ArchiveError(.external, "Could not read \(archive.lastPathComponent): \(summary)", path: archive.path)
        }
        guard !result.stdoutOverflowed else {
            throw ArchiveError(.external, "\(archive.lastPathComponent) lists too many items to show", path: archive.path)
        }
        return try ArchiveListingParser().parse(result.stdout)
    }
}

extension ArchiveEntry {
    /// `raw` is the name in the archive. The root entry ("./") gets an empty path, and the listing drops it.
    init(raw: [UInt8], kind: Kind, size: Int64?, modified: Date?) {
        let components = Self.components(of: raw)
        let safe = raw.first != UInt8(ascii: "/") && !components.contains(Array("..".utf8))
        self.path = safe
            ? components.map { String(decoding: $0, as: UTF8.self) }.joined(separator: "/")
            : String(decoding: raw, as: UTF8.self)
        self.kind = kind
        self.size = size
        self.modified = modified
        self.isSafe = safe
        self.rawPath = raw
    }

    /// Path components without "." and empty ones
    static func components(of raw: [UInt8]) -> [[UInt8]] {
        raw.split(separator: UInt8(ascii: "/")).map(Array.init).filter { $0 != [UInt8(ascii: ".")] }
    }
}

struct ArchiveListingParser {
    var now = Date()
    private let calendar = Calendar(identifier: .gregorian)
    private static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        .map { Array($0.utf8) }

    init(now: Date = Date()) { self.now = now }

    func parse(_ listing: Data) throws -> [ArchiveEntry] {
        var entries: [ArchiveEntry] = []
        for line in listing.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
            guard let entry = parseLine(Array(line)) else {
                throw ArchiveError(.external, "The archive listing has a line that cannot be read")
            }
            if !entry.path.isEmpty { entries.append(entry) }
        }
        return entries
    }

    /// Where each space-separated field of a line starts and ends
    private func fields(of line: [UInt8]) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var index = 0
        while index < line.count {
            while index < line.count, line[index] == UInt8(ascii: " ") { index += 1 }
            let start = index
            while index < line.count, line[index] != UInt8(ascii: " ") { index += 1 }
            if start < index { ranges.append(start..<index) }
        }
        return ranges
    }

    private func parseLine(_ line: [UInt8]) -> ArchiveEntry? {
        let fields = fields(of: line)
        guard fields.count >= 8, let type = line.first else { return nil }
        // After mode and link count: owner and group (any number of fields), then size, month, day, time or year, name
        var index = 2
        while index + 4 < fields.count {
            defer { index += 1 }
            let sizeField = Array(line[fields[index]])
            guard isSize(sizeField), let date = date(month: Array(line[fields[index + 1]]),
                                                     day: Array(line[fields[index + 2]]),
                                                     clock: Array(line[fields[index + 3]])) else { continue }
            // Exactly one space follows the date: more would belong to the name
            let nameStart = fields[index + 3].upperBound + 1
            guard nameStart < line.count else { return nil }
            return entry(type: type, name: Array(line[nameStart...]), size: sizeField, modified: date)
        }
        return nil
    }

    private func entry(type: UInt8, name: [UInt8], size: [UInt8], modified: Date) -> ArchiveEntry {
        var name = name
        let kind: ArchiveEntry.Kind
        switch type {
        case UInt8(ascii: "d"):
            kind = .directory
        case UInt8(ascii: "l"):
            kind = .link
            name = Self.cut(name, at: " -> ")
        case UInt8(ascii: "h"):
            kind = .link
            name = Self.cut(name, at: " link to ")
        case UInt8(ascii: "-"), UInt8(ascii: "?"):
            kind = .file
        default:
            kind = .link    // Devices and pipes: listed, never opened
        }
        return ArchiveEntry(raw: Self.unescape(name), kind: kind, size: Int64(String(decoding: size, as: UTF8.self)),
                            modified: modified)
    }

    /// Size, or major,minor for a device
    private func isSize(_ field: [UInt8]) -> Bool {
        field.allSatisfy { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) || $0 == UInt8(ascii: ",") }
    }

    private func date(month: [UInt8], day: [UInt8], clock: [UInt8]) -> Date? {
        guard let monthIndex = Self.months.firstIndex(of: month),
              let dayNumber = Int(String(decoding: day, as: UTF8.self)), (1...31).contains(dayNumber) else { return nil }
        var parts = DateComponents(month: monthIndex + 1, day: dayNumber)
        let text = String(decoding: clock, as: UTF8.self)
        if clock.count == 4, let year = Int(text) {
            parts.year = year
            return calendar.date(from: parts)
        }
        let time = text.split(separator: ":").compactMap { Int($0) }
        guard clock.count == 5, time.count == 2 else { return nil }
        parts.hour = time[0]
        parts.minute = time[1]
        parts.year = calendar.component(.year, from: now)
        // tar leaves out the year only for dates near today, so one that lands in the future is from last year
        guard let date = calendar.date(from: parts) else { return nil }
        if date.timeIntervalSince(now) > 86_400 {
            parts.year = (parts.year ?? 0) - 1
            return calendar.date(from: parts)
        }
        return date
    }

    /// Everything before the last `marker`. A name holding the marker too cannot be told apart, and shows short.
    private static func cut(_ name: [UInt8], at marker: String) -> [UInt8] {
        let pattern = Array(marker.utf8)
        var start = name.count - pattern.count
        while start >= 0 {
            if Array(name[start..<(start + pattern.count)]) == pattern { return Array(name[..<start]) }
            start -= 1
        }
        return name
    }

    /// Undoes tar's escaping back to the bytes of the name
    static func unescape(_ text: [UInt8]) -> [UInt8] {
        let simple: [UInt8: UInt8] = [UInt8(ascii: "n"): 10, UInt8(ascii: "t"): 9, UInt8(ascii: "r"): 13,
                                      UInt8(ascii: "a"): 7, UInt8(ascii: "b"): 8, UInt8(ascii: "f"): 12,
                                      UInt8(ascii: "v"): 11]
        var out: [UInt8] = []
        out.reserveCapacity(text.count)
        var index = 0
        while index < text.count {
            let byte = text[index]
            guard byte == UInt8(ascii: "\\"), index + 1 < text.count else {
                out.append(byte)
                index += 1
                continue
            }
            if let code = octal(text, at: index + 1) {
                out.append(code)
                index += 4
            } else {
                out.append(simple[text[index + 1]] ?? text[index + 1])
                index += 2
            }
        }
        return out
    }

    private static func octal(_ text: [UInt8], at start: Int) -> UInt8? {
        guard start + 2 < text.count else { return nil }
        var value = 0
        for byte in text[start...(start + 2)] {
            guard (UInt8(ascii: "0")...UInt8(ascii: "7")).contains(byte) else { return nil }
            value = value * 8 + Int(byte - UInt8(ascii: "0"))
        }
        return value <= 255 ? UInt8(value) : nil
    }
}

struct ArchiveTreeBuilder {
    func build(_ entries: [ArchiveEntry]) -> ArchiveTreeNode {
        let root = ArchiveTreeNode(name: "", entry: ArchiveEntry(raw: [], kind: .directory, size: nil, modified: nil))
        var nodes: [[UInt8]: ArchiveTreeNode] = [[]: root]

        for entry in entries {
            // An unsafe path stays one flat item at the top: nothing suggests where it would land
            let components = entry.isSafe ? ArchiveEntry.components(of: entry.rawPath) : [entry.rawPath]
            var parent: [UInt8] = []
            for (depth, component) in components.enumerated() {
                let key = parent + [0] + component
                let isLast = depth == components.count - 1
                if let node = nodes[key] {
                    // A file and a folder with one path: a folder with content stays a folder
                    if isLast {
                        if node.children.isEmpty || entry.kind == .directory { node.entry = entry }
                    } else if !node.isFolder {
                        node.entry = Self.folder(rawPath: node.entry.rawPath)
                    }
                } else {
                    let rawPath = isLast ? entry.rawPath : Array(components[...depth].joined(separator: [UInt8(ascii: "/")]))
                    let node = ArchiveTreeNode(name: Self.displayName(component),
                                               entry: isLast ? entry : Self.folder(rawPath: rawPath))
                    nodes[key] = node
                    nodes[parent]?.children.append(node)
                }
                parent = key
            }
        }
        sort(root)
        return root
    }

    private static func folder(rawPath: [UInt8]) -> ArchiveEntry {
        ArchiveEntry(raw: rawPath, kind: .directory, size: nil, modified: nil)
    }

    private func sort(_ node: ArchiveTreeNode) {
        node.children.sort {
            if $0.isFolder != $1.isFolder { return $0.isFolder }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        node.children.forEach(sort)
    }

    /// A name can hold a line break, or a text-direction mark that shows "exe.txt" for "txt.exe".
    static func displayName(_ raw: [UInt8]) -> String {
        let name = String(decoding: raw, as: UTF8.self)
        let scalars = name.unicodeScalars.map { scalar -> Unicode.Scalar in
            let bidi = (0x202A...0x202E).contains(scalar.value) || (0x2066...0x2069).contains(scalar.value)
                || scalar.value == 0x200E || scalar.value == 0x200F
            return bidi || CharacterSet.controlCharacters.contains(scalar) ? "\u{FFFD}" : scalar
        }
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        return String(view)
    }
}
