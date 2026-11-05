import Foundation
import HSpaceContracts

// Private concern: giving a password to tar without letting anything else see it.
// tar takes one on the command line, where every process can read it, or by asking. It asks on /dev/tty when it has one,
// and on its stdin otherwise. So it starts in a session of its own, which has no terminal, and finds the password on a pipe.
// Process cannot start a new session, hence posix_spawn. A session also keeps tar off the terminal of a parent shell.
// stdin ends after the password, so a wrong one ends in an error rather than in tar waiting for another try.
// Nothing here logs, and what the tool prints is scrubbed before it can reach an error.

private let longestPassword = 255
private let promptMarker = "Enter passphrase:"

/// A running child that a cancel may signal. Once reaped, its pid may belong to someone else.
private final class Child: @unchecked Sendable {
    private let lock = NSLock()
    private var pid: pid_t?

    init(pid: pid_t) {
        self.pid = pid
    }

    func terminate() {
        lock.withLock {
            if let pid { kill(pid, SIGTERM) }
        }
    }

    /// Blocks a thread that is not part of the Swift concurrency pool
    func waitForExit() async -> Int32 {
        guard let pid = lock.withLock({ pid }) else { return -1 }
        return await withCheckedContinuation { (done: CheckedContinuation<Int32, Never>) in
            DispatchQueue.global(qos: .utility).async { [self] in
                var status: Int32 = 0
                while waitpid(pid, &status, 0) < 0, errno == EINTR {}
                lock.withLock { self.pid = nil }
                let exited = status & 0x7F == 0
                done.resume(returning: exited ? (status >> 8) & 0xFF : 128 + (status & 0x7F))
            }
        }
    }
}

extension ArchiveEngineNode {
    /// A password has to fit one line of input
    static func checkPassword(_ password: String) throws {
        guard password.utf8.count <= longestPassword else {
            throw ArchiveError(.logic, "The password is too long")
        }
        guard !password.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
            throw ArchiveError(.logic, "The password holds a control character")
        }
    }

    /// Runs tar in a session without a terminal, with the password on its stdin. Cancelling stops it.
    func runWithPassword(_ tool: String, _ arguments: [String], password: String, archive: URL) async throws {
        try Self.checkPassword(password)
        guard FileManager.default.isExecutableFile(atPath: tool) else {
            throw ArchiveError(.external, "System tool missing:\(tool)", path: tool)
        }
        try Task.checkCancellation()
        let input = Pipe()
        let errors = Pipe()
        let drain = PipeDrain(errors)
        let child = try Self.spawnInNewSession(tool, arguments, stdin: input, stderr: errors)
        try? errors.fileHandleForWriting.close()    // The child has its own copy; this one would keep the drain open
        try? input.fileHandleForReading.close()

        let writer = input.fileHandleForWriting
        // A write after the tool exited must fail, not raise SIGPIPE in the app. A pipe holds far more than a password.
        _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
        try? writer.write(contentsOf: Data(password.utf8) + Data([0x0A]))    // Only fails if tar is gone: the exit status tells
        try? writer.close()

        let status = await withTaskCancellationHandler {
            await child.waitForExit()
        } onCancel: {
            child.terminate()
        }
        let output = String(decoding: drain.wait(), as: UTF8.self)
        if Task.isCancelled { throw CancellationError() }
        guard status != 0 else { return }
        // tar asks once per try, and says so in the end
        if output.components(separatedBy: promptMarker).count > 2 || output.contains("incorrect passphrase") {
            throw ArchiveError(wrongPasswordFor: archive)
        }
        let summary = Self.lastMessage(output, hiding: password)
        throw ArchiveError(.external, "tar failed:\(summary.isEmpty ? "exit code\(status)" : summary)", path: archive.path)
    }

    private static func lastMessage(_ output: String, hiding secret: String) -> String {
        let line = output.replacingOccurrences(of: promptMarker, with: "\n")
            .replacingOccurrences(of: secret, with: "***")
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty && !$0.hasPrefix("tar: Error exit delayed") } ?? ""
        return line.count > 200 ? String(line.prefix(200)) + "…" : line
    }

    private static func spawnInNewSession(_ tool: String, _ arguments: [String], stdin: Pipe, stderr: Pipe) throws -> Child {
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }
        posix_spawn_file_actions_adddup2(&actions, stdin.fileHandleForReading.fileDescriptor, 0)
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, stderr.fileHandleForWriting.fileDescriptor, 2)
        // Everything else stays closed in the child
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))

        let argv = ([tool] + arguments).map { strdup($0) } + [nil]
        let envp = utf8Environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, tool, &actions, &attributes, argv, envp)
        guard result == 0 else {
            throw ArchiveError(.external, "Could not launch tool\(tool): \(String(cString: strerror(result)))", path: tool)
        }
        return Child(pid: pid)
    }

    func passwordUnlocks(_ password: String, _ archive: URL) async throws -> Bool {
        let files = try await listEntries(archive).filter { $0.kind == .file && $0.isSafe }
        guard let smallest = files.min(by: { ($0.size ?? 0) < ($1.size ?? 0) }) else { return true }
        let scratch = try Self.createScratchDirectory()
        defer { try? Self.removeScratchDirectory(scratch) }     // At most one file of the user's own archive, in a private folder
        do {
            _ = try await extractEntries([smallest], from: archive, into: scratch, password: password)
            return true
        } catch let error as ArchiveError where error.errorClass == .external {
            return false    // Besides a refusal, a wrong password can pass the quick check and fail the checksum
        }
    }
}
