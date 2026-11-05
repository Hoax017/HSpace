import Darwin
import Foundation

// Private concern: checking new names against each other and against the disk

func itemExists(_ url: URL) -> Bool {
    var info = stat()
    return lstat(url.path, &info) == 0   // lstat: a dangling link holds its name too
}

/// How a volume compares names. APFS ignores normalization everywhere, and case unless formatted otherwise.
/// When the volume cannot be asked, names are treated as case-insensitive: that can only block a rename, never lose a file.
struct NameComparer {
    private var insensitiveByFolder: [URL: Bool] = [:]

    mutating func key(_ name: String, in folder: URL) -> String {
        let normalized = name.precomposedStringWithCanonicalMapping
        return isCaseInsensitive(folder) ? normalized.lowercased() : normalized
    }

    private mutating func isCaseInsensitive(_ folder: URL) -> Bool {
        if let known = insensitiveByFolder[folder] { return known }
        let values = try? folder.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
        let insensitive = values?.volumeSupportsCaseSensitiveNames != true
        insensitiveByFolder[folder] = insensitive
        return insensitive
    }
}

struct NameSlot: Hashable {
    let folder: URL
    let key: String
}

func validityIssue(of name: String) -> RenameIssue? {
    if name.isEmpty { return .emptyName }
    if name == "." || name == ".." { return .invalidName }
    if name.unicodeScalars.contains(where: { $0 == "/" || $0 == ":" || $0.value < 0x20 || $0.value == 0x7F }) {
        return .invalidName
    }
    if name.utf8.count > 255 { return .nameTooLong }
    return nil
}

func checkedPlan(sources: [URL], names: [String]) -> RenamePlan {
    var comparer = NameComparer()
    let folders = sources.map { $0.deletingLastPathComponent() }
    let currentSlots = zip(sources, folders).map { NameSlot(folder: $1, key: comparer.key($0.lastPathComponent, in: $1)) }
    let finalSlots = zip(names, folders).map { NameSlot(folder: $1, key: comparer.key($0, in: $1)) }

    var claims: [NameSlot: Int] = [:]
    for slot in finalSlots { claims[slot, default: 0] += 1 }

    // An unchanged row does not give up its name. A name differing only by case is the row's own and is changed.
    let isUnchanged = zip(sources, names).map { $0.lastPathComponent == $1 }
    let leaving = Set(zip(currentSlots, isUnchanged).filter { !$1 }.map(\.0))

    let rows = sources.indices.map { i -> RenamePlanRow in
        let source = sources[i], name = names[i]
        let status: RenameRowStatus
        if let issue = validityIssue(of: name) {
            status = .blocked(issue)
        } else if !itemExists(source) {
            status = .blocked(.sourceMissing)
        } else if claims[finalSlots[i], default: 0] > 1 {
            status = .blocked(.duplicateInBatch)
        } else if isUnchanged[i] {
            status = .unchanged
        } else if itemExists(folders[i].appendingPathComponent(name)), !leaving.contains(finalSlots[i]) {
            status = .blocked(.existsOnDisk)
        } else {
            status = .ready
        }
        return RenamePlanRow(source: source, newName: name, status: status)
    }
    return RenamePlan(rows: rows)
}
