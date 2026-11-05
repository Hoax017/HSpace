import Foundation
import HSpaceContracts

// Private concern: extended attributes, as macOS itself stores them. XATTR_NOFOLLOW everywhere: a symlink keeps its own
// metadata and tagging it never changes the file it points to.

let tagsAttribute = "com.apple.metadata:_kMDItemUserTags"
private let commentAttribute = "com.apple.metadata:kMDItemFinderComment"
private let finderInfoAttribute = "com.apple.FinderInfo"
private let finderInfoSize = 32
/// Byte 9 of FinderInfo holds the label number in bits 1 to 3, for files and folders alike
private let labelByte = 9
private let labelMask: UInt8 = 0b0000_1110

/// The attribute's bytes, nil when the item does not have it
func readAttribute(_ name: String, of url: URL) throws -> Data? {
    let size = url.withUnsafeFileSystemRepresentation { path in
        getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
    }
    if size < 0 {
        if errno == ENOATTR { return nil }
        throw metadataError(errno, url)
    }
    var data = Data(count: size)
    guard size > 0 else { return data }
    let read = data.withUnsafeMutableBytes { bytes in
        url.withUnsafeFileSystemRepresentation { path in
            getxattr(path, name, bytes.baseAddress, size, 0, XATTR_NOFOLLOW)
        }
    }
    guard read >= 0 else {
        if errno == ENOATTR { return nil }
        throw metadataError(errno, url)
    }
    return data.prefix(read)
}

func writeAttribute(_ name: String, _ data: Data, of url: URL) throws {
    let result = data.withUnsafeBytes { bytes in
        url.withUnsafeFileSystemRepresentation { path in
            setxattr(path, name, bytes.baseAddress, data.count, 0, XATTR_NOFOLLOW)
        }
    }
    guard result == 0 else { throw metadataError(errno, url) }
}

func removeAttribute(_ name: String, of url: URL) throws {
    let result = url.withUnsafeFileSystemRepresentation { path in
        removexattr(path, name, XATTR_NOFOLLOW)
    }
    if result != 0, errno != ENOATTR { throw metadataError(errno, url) }
}

func restoreAttribute(_ name: String, _ data: Data?, of url: URL) throws {
    if let data {
        try writeAttribute(name, data, of: url)
    } else {
        try removeAttribute(name, of: url)
    }
}

func metadataError(_ code: Int32, _ url: URL) -> MetadataError {
    let name = url.lastPathComponent
    switch code {
    case EACCES, EPERM, EROFS:
        return MetadataError(.external, "No permission to change \"\(name)\"")
    case ENOENT, ENOTDIR:
        return MetadataError(.external, "\"\(name)\" is no longer there")
    case ENOSPC, EDQUOT:
        return MetadataError(.external, "Not enough disk space to change \"\(name)\"")
    case ENOTSUP, EINVAL, E2BIG, ERANGE:
        return MetadataError(.external, "The volume holding \"\(name)\" cannot store this")
    case ENXIO, ENODEV, EIO:
        return MetadataError(.external, "The volume holding \"\(name)\" is not available")
    default:
        return MetadataError(.transient, "Could not change \"\(name)\": \(String(cString: strerror(code)))")
    }
}

// MARK: Tags

/// Reads the tag list. Throws when the attribute is damaged, because writing over it would lose what it holds.
func readTags(of url: URL) throws -> [FinderTag] {
    if let data = try readAttribute(tagsAttribute, of: url) {
        return try decodeTags(data, of: url)
    }
    // Old items have only a Finder label, which macOS still shows as a tag
    guard let info = try readAttribute(finderInfoAttribute, of: url), info.count == finderInfoSize else { return [] }
    let number = Int(info[info.startIndex + labelByte] & labelMask) >> 1
    return FinderTag.standard.filter { $0.color.rawValue == number }
}

private func decodeTags(_ data: Data, of url: URL) throws -> [FinderTag] {
    let value: Any
    do {
        value = try PropertyListSerialization.propertyList(from: data, format: nil)
    } catch {
        throw damagedTags(url)
    }
    guard let entries = value as? [String] else { throw damagedTags(url) }
    return entries.compactMap { entry in
        let parts = entry.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard let name = parts.first, !name.isEmpty else { return nil }
        let number = parts.count > 1 ? Int(parts[1]) : nil
        return FinderTag(name: String(name), color: number.flatMap(TagColor.init(rawValue:)) ?? .none)
    }
}

private func damagedTags(_ url: URL) -> MetadataError {
    MetadataError(.external, "The tags of \"\(url.lastPathComponent)\" are damaged, so they were left alone")
}

/// Stores the list and keeps the Finder label in step, as macOS does: the label is the last coloured tag.
/// A label left behind would come back as a tag the user has removed.
func writeTags(_ tags: [FinderTag], to url: URL) throws {
    let previous = try readAttribute(tagsAttribute, of: url)
    if tags.isEmpty {
        try removeAttribute(tagsAttribute, of: url)
    } else {
        let entries = tags.map { "\($0.name)\n\($0.color.rawValue)" }
        let data: Data
        do {
            data = try PropertyListSerialization.data(fromPropertyList: entries, format: .binary, options: 0)
        } catch {
            throw MetadataError(.logic, "Could not encode the tags of \"\(url.lastPathComponent)\"")
        }
        try writeAttribute(tagsAttribute, data, of: url)
    }
    do {
        try writeLabel(tags.last { $0.color != .none }?.color ?? .none, to: url)
    } catch {
        // Half a change would show different tags in Finder and here
        try restoreAttribute(tagsAttribute, previous, of: url)
        throw error
    }
}

/// Changes only the label bits: the same 32 bytes hold the custom-icon flag and the file type.
private func writeLabel(_ color: TagColor, to url: URL) throws {
    var info = try readAttribute(finderInfoAttribute, of: url) ?? Data()
    guard info.isEmpty || info.count == finderInfoSize else {
        throw MetadataError(.external, "The Finder information of \"\(url.lastPathComponent)\" is damaged")
    }
    if info.isEmpty {
        guard color != .none else { return }
        info = Data(count: finderInfoSize)
    }
    info = Data(info)
    info[labelByte] = (info[labelByte] & ~labelMask) | (UInt8(color.rawValue) << 1)
    if info.allSatisfy({ $0 == 0 }) {
        try removeAttribute(finderInfoAttribute, of: url)
    } else {
        try writeAttribute(finderInfoAttribute, info, of: url)
    }
}

// MARK: Comments

/// Throws when the attribute is damaged, for the same reason as `readTags`
func readComment(of url: URL) throws -> String? {
    guard let data = try readAttribute(commentAttribute, of: url) else { return nil }
    let damaged = MetadataError(.external, "The comment of \"\(url.lastPathComponent)\" is damaged, so it was left alone")
    let value: Any
    do {
        value = try PropertyListSerialization.propertyList(from: data, format: nil)
    } catch {
        throw damaged
    }
    guard let text = value as? String else { throw damaged }
    return text.isEmpty ? nil : text
}

func writeComment(_ comment: String?, to url: URL) throws {
    guard let comment, !comment.isEmpty else {
        try removeAttribute(commentAttribute, of: url)
        return
    }
    let data: Data
    do {
        data = try PropertyListSerialization.data(fromPropertyList: comment, format: .binary, options: 0)
    } catch {
        throw MetadataError(.logic, "Could not encode the comment of \"\(url.lastPathComponent)\"")
    }
    try writeAttribute(commentAttribute, data, of: url)
}

// MARK: File colour (HSpace's own attribute: it travels with the file, and Finder ignores it)

private let colorAttribute = "com.hoax017.hspace.fileColor"

/// A value from a newer version reads as no colour
func readColor(of url: URL) throws -> FileColor? {
    guard let data = try readAttribute(colorAttribute, of: url) else { return nil }
    return FileColor(rawValue: String(decoding: data, as: UTF8.self))
}

func writeColor(_ color: FileColor?, to url: URL) throws {
    guard let color else {
        try removeAttribute(colorAttribute, of: url)
        return
    }
    try writeAttribute(colorAttribute, Data(color.rawValue.utf8), of: url)
}

func validate(_ tags: [FinderTag]) throws {
    for tag in tags where tag.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || tag.name.contains("\n") {
        throw MetadataError(.logic, "A tag name cannot be empty or hold a line break")
    }
}
