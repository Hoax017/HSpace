import Darwin
import Foundation
import Synchronization

/// Why an external open was refused. Messages are shown to the user and never repeat the path, which came from another app.
enum ExternalOpenRejection: Error, Equatable, Sendable {
    case unsupportedAction, invalidPath, remotePath, notFound, notADirectory, timedOut

    var message: String {
        switch self {
        case .unsupportedAction: L10n.t("externalOpen.unsupportedAction")
        case .invalidPath: L10n.t("externalOpen.invalidPath")
        case .remotePath: L10n.t("externalOpen.remotePath")
        case .notFound: L10n.t("externalOpen.notFound")
        case .notADirectory: L10n.t("externalOpen.notADirectory")
        case .timedOut: L10n.t("externalOpen.timedOut")
        }
    }
}

/// One external open, before anything has looked at the disk.
enum ExternalRequest: Equatable, Sendable {
    /// `hspace://open`: go to a local directory.
    case open(URL)
    /// `hspace://reveal`: go to the parent of a local item and select it.
    case reveal(URL)
    /// A file URL from LaunchServices or the Services menu: the user chose it, so network volumes stay allowed.
    case system(URL)
    case rejected(ExternalOpenRejection)
}

struct ExternalDestination: Equatable, Sendable {
    var directory: URL
    var selecting: URL?
}

struct ExternalOpenPlan: Equatable, Sendable {
    var destinations: [ExternalDestination] = []
    var rejections: [ExternalOpenRejection] = []
}

/// `hspace://` links come from any web page or app, so they can only navigate. Parsing works on the text alone and is safe
/// on the main thread: asking the file system about `/net/host` is exactly what would hang it.
enum HSpaceURL {
    static func parse(_ url: URL) -> ExternalRequest {
        guard url.scheme?.lowercased() == "hspace",
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              comps.user == nil, comps.password == nil, comps.port == nil, comps.path.isEmpty,
              let action = comps.host?.lowercased(), action == "open" || action == "reveal"
        else { return .rejected(.unsupportedAction) }
        guard let items = comps.queryItems, items.count == 1, items[0].name == "path",
              let path = items[0].value
        else { return .rejected(.invalidPath) }
        if let rejection = LocalPathPolicy.check(path) { return .rejected(rejection) }
        let target = URL(fileURLWithPath: path)
        return action == "open" ? .open(target) : .reveal(target)
    }
}

/// Which paths an `hspace://` link may name.
enum LocalPathPolicy {
    /// Text-only check: never touches the disk.
    static func check(_ path: String) -> ExternalOpenRejection? {
        guard path.hasPrefix("/"), !path.contains("\0") else { return .invalidPath }
        let components = split(path)
        guard !components.contains("..") else { return .invalidPath }
        return isAutomount(components) ? .remotePath : nil
    }

    static func split(_ path: String) -> [String] {
        path.split(separator: "/").map(String.init)
    }

    private static let automountRoots: [[String]] = [
        ["net"], ["network"], ["home"], ["var", "automount"], ["private", "var", "automount"],
    ]
    private static let dataVolume = ["system", "volumes", "data"]

    /// Compared in lowercase because the default file system ignores case, so `/NET/host` is `/net/host`.
    static func isAutomount(_ components: [String]) -> Bool {
        var lowered = components.map { $0.lowercased() }
        // The kernel's own path spellings (/.vol, /.nofollow, /.resolve) reach the same places under another name
        if lowered.first?.hasPrefix(".") == true { return true }
        if lowered.starts(with: dataVolume) { lowered.removeFirst(dataVolume.count) }
        return automountRoots.contains { lowered.starts(with: $0) }
    }

    /// Follows `path` one component at a time, so a symlink into an automount is refused before anything reaches through it.
    /// Blocks on a dead mount: call it through `ExternalOpenWorker`.
    static func resolve(_ path: String) -> Result<String, ExternalOpenRejection> {
        var pending = Array(split(path).reversed())
        var resolved: [String] = []
        var linksFollowed = 0
        while let component = pending.popLast() {
            if component == "." { continue }
            if component == ".." {
                _ = resolved.popLast()
                continue
            }
            let candidate = resolved + [component]
            if isAutomount(candidate) { return .failure(.remotePath) }
            let candidatePath = "/" + candidate.joined(separator: "/")
            var info = Darwin.stat()
            guard lstat(candidatePath, &info) == 0 else { return .failure(.notFound) }
            guard info.st_mode & S_IFMT == S_IFLNK else {
                resolved = candidate
                continue
            }
            linksFollowed += 1
            guard linksFollowed <= 32, let target = linkTarget(candidatePath) else { return .failure(.invalidPath) }
            if target.hasPrefix("/") { resolved = [] }
            pending.append(contentsOf: split(target).reversed())
        }
        let resolvedPath = "/" + resolved.joined(separator: "/")
        return isLocalVolume(resolvedPath) ? .success(resolvedPath) : .failure(.remotePath)
    }

    private static func linkTarget(_ path: String) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let length = readlink(path, &buffer, Int(PATH_MAX))
        guard length > 0 else { return nil }
        return String(decoding: buffer[..<length].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func isLocalVolume(_ path: String) -> Bool {
        var volume = statfs()
        guard statfs(path, &volume) == 0 else { return false }
        let local = volume.f_flags & UInt32(MNT_LOCAL) != 0
        let automounted = volume.f_flags & UInt32(MNT_AUTOMOUNTED) != 0
        return local && !automounted
    }
}

/// Turns requests into destinations. Reads the disk: call it through `ExternalOpenWorker`.
enum ExternalOpenPlanner {
    static func plan(_ requests: [ExternalRequest]) -> ExternalOpenPlan {
        var plan = ExternalOpenPlan()
        for request in requests {
            switch destination(for: request) {
            case .success(let destination): plan.merge(destination)
            case .failure(let rejection): plan.rejections.append(rejection)
            }
        }
        return plan
    }

    private static func destination(for request: ExternalRequest) -> Result<ExternalDestination, ExternalOpenRejection> {
        switch request {
        case .rejected(let rejection):
            return .failure(rejection)
        case .system(let url):
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return .failure(.notFound) }
            return .success(isDirectory.boolValue
                ? ExternalDestination(directory: url, selecting: nil)
                : ExternalDestination(directory: url.deletingLastPathComponent(), selecting: url))
        case .open(let url):
            return LocalPathPolicy.resolve(url.path).flatMap { path in
                var info = Darwin.stat()
                guard stat(path, &info) == 0 else { return .failure(.notFound) }
                guard info.st_mode & S_IFMT == S_IFDIR else { return .failure(.notADirectory) }
                return .success(ExternalDestination(directory: URL(fileURLWithPath: path), selecting: nil))
            }
        case .reveal(let url):
            return LocalPathPolicy.resolve(url.path).map { path in
                let target = URL(fileURLWithPath: path)
                return path == "/"
                    ? ExternalDestination(directory: target, selecting: nil)
                    : ExternalDestination(directory: target.deletingLastPathComponent(), selecting: target)
            }
        }
    }
}

private extension ExternalOpenPlan {
    /// One destination per directory: a single "Reveal in Finder" often brings several files from one folder,
    /// and opening one workspace per file would duplicate the whole layout each time.
    mutating func merge(_ destination: ExternalDestination) {
        guard let index = destinations.firstIndex(where: { $0.directory == destination.directory }) else {
            destinations.append(destination)
            return
        }
        if destinations[index].selecting == nil { destinations[index].selecting = destination.selecting }
    }
}

/// Earlier versions kept the last externally opened path in defaults as a diagnostic.
enum ExternalOpenHistory {
    static func purgeStoredPath(from defaults: UserDefaults) {
        defaults.removeObject(forKey: "debug.lastExternalOpen")
    }
}

/// Runs disk checks away from the main thread and stops waiting after `timeout`. A thread stuck in the kernel cannot be
/// cancelled, so the queue also caps how many a dead mount can hold at once.
final class ExternalOpenWorker: Sendable {
    private let queue: OperationQueue
    private let timeout: TimeInterval

    init(timeout: TimeInterval = 5) {
        self.timeout = timeout
        queue = OperationQueue()
        queue.name = "HSpace external open"
        queue.maxConcurrentOperationCount = 4
    }

    /// nil means the work did not answer in time.
    func run<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T? {
        await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            let answer = SingleAnswer(continuation)
            queue.addOperation { answer.resume(work()) }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { answer.resume(nil) }
        }
    }
}

/// The work and the timeout race; whichever comes second is ignored.
private final class SingleAnswer<T: Sendable>: Sendable {
    private let continuation: Mutex<CheckedContinuation<T?, Never>?>

    init(_ continuation: CheckedContinuation<T?, Never>) {
        self.continuation = Mutex(continuation)
    }

    func resume(_ value: T?) {
        continuation.withLock { pending in
            pending?.resume(returning: value)
            pending = nil
        }
    }
}
