import Foundation

/// Constructor-injected directory lister (Axiom 2): the real file system by default, tests inject an in-memory fixture
public struct PathCompleter: PathCompleting {
    /// Directory path → names of its subdirectories
    private let listSubdirectories: @Sendable (String) -> [String]
    private let homePath: String

    public init() {
        self.init(homePath: NSHomeDirectory(), listSubdirectories: Self.realLister)
    }

    public init(homePath: String, listSubdirectories: @escaping @Sendable (String) -> [String]) {
        self.homePath = homePath
        self.listSubdirectories = listSubdirectories
    }

    public func complete(_ input: String) -> [String] {
        guard !input.isEmpty else { return [] }
        var expanded = input
        if expanded == "~" { expanded = homePath + "/" }
        else if expanded.hasPrefix("~/") { expanded = homePath + String(expanded.dropFirst(1)) }
        guard expanded.hasPrefix("/") else { return [] }

        let dir: String
        let prefix: String
        if expanded.hasSuffix("/") {
            dir = expanded
            prefix = ""
        } else {
            let ns = expanded as NSString
            dir = ns.deletingLastPathComponent.hasSuffix("/")
                ? ns.deletingLastPathComponent
                : ns.deletingLastPathComponent + "/"
            prefix = ns.lastPathComponent
        }

        return listSubdirectories(dir)
            .filter { prefix.isEmpty || $0.range(of: prefix, options: [.caseInsensitive, .anchored]) != nil }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { dir + $0 + "/" }
    }

    @Sendable private static func realLister(_ dir: String) -> [String] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return [] }
        return names.filter { name in
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: dir + name, isDirectory: &isDir) && isDir.boolValue
        }
    }
}
