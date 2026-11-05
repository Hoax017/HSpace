import Foundation
import UniformTypeIdentifiers
import HSpaceContracts

/// A user-named set of file kinds, such as "Images". It matches by system type, which also covers subtypes, or by extension.
public struct KindGroup: Sendable, Hashable, Codable, Identifiable {
    public let id: UUID
    public var name: String
    /// Without the dot, compared without regard to case
    public var extensions: [String]
    /// Uniform type identifiers, for example "public.image"
    public var typeIDs: [String]

    public init(id: UUID = UUID(), name: String, extensions: [String] = [], typeIDs: [String] = []) {
        self.id = id
        self.name = name
        self.extensions = extensions
        self.typeIDs = typeIDs
    }
}

public enum KindGroups {
    /// The starting list. `localized` turns each name key into the display name.
    public static func defaults(localized: (String) -> String) -> [KindGroup] {
        [
            KindGroup(name: localized("kindGroup.folders"), typeIDs: ["public.folder"]),
            KindGroup(name: localized("kindGroup.applications"), typeIDs: ["com.apple.application"]),
            KindGroup(name: localized("kindGroup.images"), typeIDs: ["public.image"]),
            KindGroup(name: localized("kindGroup.movies"), typeIDs: ["public.movie"]),
            KindGroup(name: localized("kindGroup.audio"), typeIDs: ["public.audio"]),
            // Before Documents: source code counts as plain text
            KindGroup(name: localized("kindGroup.code"), typeIDs: ["public.source-code", "public.script"]),
            KindGroup(name: localized("kindGroup.documents"),
                      extensions: ["doc", "docx", "xls", "xlsx", "ppt", "pptx", "pages", "numbers", "key"],
                      typeIDs: ["com.adobe.pdf", "public.rtf", "public.plain-text", "public.html"]),
            KindGroup(name: localized("kindGroup.archives"), extensions: ["rar", "7z"], typeIDs: ["public.archive"]),
        ]
    }

    /// For each item, the index of the first group that matches, or nil. Grouping order is the list's order, so a user can
    /// move a narrow group above a broad one. Each type is worked out once, which keeps a very large folder fast.
    public static func assign(_ items: [FileItem], to groups: [KindGroup]) -> [Int?] {
        let extensionOwners = extensionTable(groups)
        var typeOwners: [String: Int?] = [:]
        return items.map { item in
            let viaType = item.contentTypeID.flatMap { typeOwner($0, groups, &typeOwners) }
            let own = item.isDirectory ? "" : (item.name as NSString).pathExtension.lowercased()
            return [viaType, own.isEmpty ? nil : extensionOwners[own]].compactMap { $0 }.min()
        }
    }

    private static func extensionTable(_ groups: [KindGroup]) -> [String: Int] {
        var table: [String: Int] = [:]
        for (index, group) in groups.enumerated() {
            for name in group.extensions where table[name.lowercased()] == nil {
                table[name.lowercased()] = index
            }
        }
        return table
    }

    private static func typeOwner(_ typeID: String, _ groups: [KindGroup], _ cache: inout [String: Int?]) -> Int? {
        if let known = cache[typeID] { return known }
        let type = UTType(typeID)
        let found = groups.firstIndex { group in
            group.typeIDs.contains { wanted in
                wanted == typeID || UTType(wanted).flatMap { parent in type?.conforms(to: parent) } == true
            }
        }
        cache[typeID] = .some(found)
        return found
    }
}
