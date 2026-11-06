// swift-tools-version: 6.1
import PackageDescription

// Pod list: adding a capability = append a name here + create a Sources/Pods/<name>/ directory (the single explicit point of BG-11 incremental addition)
let pods: [String] = ["DirectoryReader", "Transfer", "PathComplete", "DirectoryWatch", "FolderSize", "IconThumb", "LocalOps", "VolumeInfo", "BookmarkStore", "SessionStore", "StashStore", "SearchEngine", "ArchiveEngine", "Frecency", "Eraser", "TrashLedger", "FileMetadata", "BatchRename", "FileHash", "ImageConvert", "Scheduler", "OperationHistory", "FolderSync", "FileTemplates", "ArchivePasswords", "SidePanel", "FileInspector", "ViewStyles", "HiddenRules", "KeyboardSelection", "PhotoLibrary", "TabNavigation", "QuickLocations", "QuickLauncher", "SidebarColors"]

let podTargets: [Target] = pods.map {
    .target(name: $0, dependencies: ["HSpaceContracts"], path: "Sources/Pods/\($0)")
}
let podTestTargets: [Target] = pods.map {
    .testTarget(name: "\($0)Tests", dependencies: [.target(name: $0), "HSpaceContracts", "HSpaceTestSupport"])
}
let podDeps: [Target.Dependency] = pods.map { .target(name: $0) }

let package = Package(
    name: "HSpace",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "HSpace", targets: ["HSpaceApp"]),
        .executable(name: "hspace-probe", targets: ["HSpaceProbe"]),
    ],
    targets: [
        .target(name: "HSpaceContracts"),
        .target(name: "HSpaceKernel", dependencies: ["HSpaceContracts"]),
        .executableTarget(
            name: "HSpaceApp",
            dependencies: ["HSpaceKernel", "HSpaceContracts"] + podDeps
        ),
        .executableTarget(
            name: "HSpaceProbe",
            dependencies: ["HSpaceKernel", "HSpaceContracts"] + podDeps
        ),
        .target(name: "HSpaceTestSupport", path: "Tests/HSpaceTestSupport"),
        .testTarget(name: "HSpaceTestSupportTests", dependencies: ["HSpaceTestSupport"]),
        .testTarget(name: "HSpaceKernelTests", dependencies: ["HSpaceKernel", "HSpaceContracts"]),
        .testTarget(name: "HSpaceAppTests", dependencies: ["HSpaceApp", "HSpaceContracts", "HSpaceTestSupport"] + podDeps),
    ] + podTargets + podTestTargets
)
