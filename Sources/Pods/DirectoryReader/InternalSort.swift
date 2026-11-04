import Foundation
import NSpaceContracts

// Private concern: Finder-style sorting (localizedStandardCompare, optional folders first)
// Three-way comparison keeps strict weak ordering (in descending order equal elements must not both compare "less", or sort crashes)

func sortItems(_ items: inout [FileItem], by order: SortSpec) {
    items.sort { a, b in
        // Finder style: folders-first applies only when sorting by name; sorting by date/size/kind mixes purely by that column
        // (folders and files interleaved): the user explicitly said "sorting by time should be purely by time" (I-50).
        if order.foldersFirst && order.key == .name {
            let aDir = a.isDirectory && !a.isPackage
            let bDir = b.isDirectory && !b.isPackage
            if aDir != bDir { return aDir }
        }
        let cmp: ComparisonResult
        switch order.key {
        case .name:
            cmp = a.name.localizedStandardCompare(b.name)
        case .dateModified:
            cmp = compare(a.modified ?? .distantPast, b.modified ?? .distantPast)
        case .created:
            cmp = compare(a.created ?? .distantPast, b.created ?? .distantPast)
        case .added:
            cmp = compare(a.added ?? .distantPast, b.added ?? .distantPast)
        case .size:
            cmp = compare(a.size ?? -1, b.size ?? -1)
        case .kind:
            cmp = compare(a.contentTypeID ?? "", b.contentTypeID ?? "")
        }
        if cmp == .orderedSame {
            // On equal keys break ties by name, always ascending (independent of main direction, for a stable look)
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        return order.ascending ? cmp == .orderedAscending : cmp == .orderedDescending
    }
}

private func compare<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult {
    if a < b { return .orderedAscending }
    if a > b { return .orderedDescending }
    return .orderedSame
}
