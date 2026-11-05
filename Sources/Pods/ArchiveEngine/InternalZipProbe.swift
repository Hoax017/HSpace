import Foundation
import HSpaceContracts

// Private concern: whether a zip holds encrypted entries, read from its central directory.
// tar's listing does not say. Everything read here is untrusted, so every offset is checked against what was really read,
// and a file that does not parse counts as not encrypted: extraction then fails with the tool's own message.

private let centralDirectoryLimit = 256 << 20

private struct ZipBytes {
    let data: Data

    func u16(_ at: Int) -> Int? {
        guard at >= 0, at + 2 <= data.count else { return nil }
        let base = data.startIndex + at
        return Int(data[base]) | Int(data[base + 1]) << 8
    }

    func u32(_ at: Int) -> Int? {
        guard let low = u16(at), let high = u16(at + 2) else { return nil }
        return low | high << 16
    }

    func u64(_ at: Int) -> Int? {
        guard let low = u32(at), let high = u32(at + 4), high < 1 << 30 else { return nil }
        return low | high << 32
    }

    func isSignature(_ at: Int, _ signature: [UInt8]) -> Bool {
        guard at >= 0, at + signature.count <= data.count else { return false }
        return data[(data.startIndex + at)..<(data.startIndex + at + signature.count)].elementsEqual(signature)
    }
}

enum ZipProbe {
    private static let endRecord: [UInt8] = [0x50, 0x4B, 0x05, 0x06]
    private static let locator64: [UInt8] = [0x50, 0x4B, 0x06, 0x07]
    private static let endRecord64: [UInt8] = [0x50, 0x4B, 0x06, 0x06]
    private static let fileHeader: [UInt8] = [0x50, 0x4B, 0x01, 0x02]

    static func hasEncryptedEntries(_ url: URL) throws -> Bool {
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }   // Read only
            let size = Int(try handle.seekToEnd())
            guard let directory = try centralDirectory(handle, size: size) else { return false }
            return scan(ZipBytes(data: directory))
        } catch {
            throw ArchiveError(.external, "Could not read \(url.lastPathComponent): \(error.localizedDescription)", path: url.path)
        }
    }

    private static func read(_ handle: FileHandle, at offset: Int, count: Int) throws -> Data {
        try handle.seek(toOffset: UInt64(offset))
        return try handle.read(upToCount: count) ?? Data()
    }

    private static func centralDirectory(_ handle: FileHandle, size: Int) throws -> Data? {
        // The end record sits in the last 64 KB, after a comment of up to 65,535 bytes
        let tailStart = max(0, size - (22 + 0xFFFF))
        let tail = ZipBytes(data: try read(handle, at: tailStart, count: size - tailStart))
        var end = tail.data.count - 22
        while end >= 0, !tail.isSignature(end, endRecord) { end -= 1 }
        guard end >= 0, var directorySize = tail.u32(end + 12), var directoryOffset = tail.u32(end + 16) else { return nil }
        var directoryEnd = tailStart + end

        if directorySize == 0xFFFF_FFFF || directoryOffset == 0xFFFF_FFFF, tail.isSignature(end - 20, locator64),
           let recordOffset = tail.u64(end - 20 + 8), recordOffset >= 0, recordOffset + 56 <= size {
            let record = ZipBytes(data: try read(handle, at: recordOffset, count: 56))
            guard record.isSignature(0, endRecord64), let size64 = record.u64(40), let offset64 = record.u64(48) else {
                return nil
            }
            directorySize = size64
            directoryOffset = offset64
            directoryEnd = recordOffset
        }
        // A self-extracting stub in front moves everything, and the offsets do not say so
        let start = directoryEnd - directorySize
        guard directorySize > 0, directorySize <= centralDirectoryLimit, start >= 0, directoryOffset >= 0 else { return nil }
        return try read(handle, at: start, count: directorySize)
    }

    private static func scan(_ directory: ZipBytes) -> Bool {
        var at = 0
        while directory.isSignature(at, fileHeader) {
            guard let flags = directory.u16(at + 8), let name = directory.u16(at + 28),
                  let extra = directory.u16(at + 30), let comment = directory.u16(at + 32) else { return false }
            if flags & 1 == 1 { return true }
            at += 46 + name + extra + comment
        }
        return false
    }
}
