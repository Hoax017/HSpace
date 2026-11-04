import Foundation
import UniformTypeIdentifiers
import NSpaceContracts

// Private concern: contentsOfDirectory + resource key prefetch (one system call fetches all metadata needed for display)

private let prefetchKeys: [URLResourceKey] = [
    .nameKey, .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .isHiddenKey,
    .fileSizeKey, .contentModificationDateKey, .creationDateKey, .addedToDirectoryDateKey, .contentTypeKey,
]

func scanDirectory(_ request: ReadRequest) throws -> [FileItem] {
    let fm = FileManager.default
    let urls: [URL]
    do {
        urls = try fm.contentsOfDirectory(
            at: request.directory,
            includingPropertiesForKeys: prefetchKeys,
            options: request.includeHidden ? [] : [.skipsHiddenFiles])
    } catch let e as NSError {
        let cls: ErrorClass = (e.domain == NSCocoaErrorDomain &&
            (e.code == NSFileReadNoPermissionError || e.code == NSFileReadNoSuchFileError))
            ? .external : .transient
        throw DirectoryReadError(cls, e.localizedDescription, underlying: e)
    }

    var items: [FileItem] = []
    items.reserveCapacity(urls.count)
    for url in urls {
        guard let rv = try? url.resourceValues(forKeys: Set(prefetchKeys)) else {
            // A single entry's metadata failure does not fail the whole directory: show it with minimal info (fault matrix: decoration failure must not hurt the main path)
            items.append(FileItem(url: url, name: url.lastPathComponent,
                                  isDirectory: false, isPackage: false, isSymlink: false,
                                  isHidden: false, size: nil, modified: nil, created: nil,
                                  contentTypeID: nil))
            continue
        }
        items.append(FileItem(
            url: url,
            name: rv.name ?? url.lastPathComponent,
            isDirectory: rv.isDirectory ?? false,
            isPackage: rv.isPackage ?? false,
            isSymlink: rv.isSymbolicLink ?? false,
            isHidden: rv.isHidden ?? false,
            size: (rv.isDirectory ?? false) ? nil : rv.fileSize.map(Int64.init),
            modified: rv.contentModificationDate,
            created: rv.creationDate,
            added: rv.addedToDirectoryDate,
            contentTypeID: rv.contentType?.identifier))
    }
    return items
}
