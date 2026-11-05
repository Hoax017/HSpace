import Foundation
import HSpaceContracts

// Private concern: physical Process driver: launches system tools, captures stderr while they run, cooperative cancellation (terminate).
// Process.run()/waitUntilExit() block, so terminationHandler + CheckedContinuation make this non-blocking,
// staying off the Swift concurrency cooperative pool (same spirit as Transfer's ioQueue).

struct ProcessResult {
    let status: Int32
    let stderr: String
    /// Filled only when the run asked to capture stdout
    var stdout = Data()
    /// The child wrote more stdout than the capture limit; the rest was read and dropped
    var stdoutOverflowed = false
}

/// Reads a pipe from the moment it is created. A pipe holds about 64 KB, so a child writing more
/// would block forever if the pipe were only read after the child exits.
/// Output past `limit` is read and dropped, so what an archive makes a tool print cannot grow without bound.
final class PipeDrain: @unchecked Sendable {
    private let done = DispatchGroup()
    // Written before done.leave(), read only after done.wait()
    private var data = Data()
    private var overflowed = false

    init(_ pipe: Pipe, limit: Int = 1 << 20) {
        let reader = pipe.fileHandleForReading
        done.enter()
        DispatchQueue.global(qos: .utility).async { [self] in
            // A failed read ends the capture early. What was read is diagnostics, or a listing the exit code judges.
            while let chunk = try? reader.read(upToCount: 1 << 16), !chunk.isEmpty {
                if data.count + chunk.count <= limit { data.append(chunk) } else { overflowed = true }
            }
            done.leave()
        }
    }

    func wait() -> Data {
        done.wait()
        return data
    }

    func waitForOverflow() -> Bool {
        done.wait()
        return overflowed
    }
}

extension ArchiveEngineNode {

    /// Runs one system tool until it exits; supports cancellation (outer Task cancelled → SIGTERM to the child).
    /// - stdoutTo: if given, the child's stdout goes to this file handle (used to redirect gunzip -c output).
    /// - captureStdout: if given, stdout comes back in the result, up to this many bytes.
    /// - utf8Locale: fixes the tool's locale, so names arrive as UTF-8 and dates in English whatever the app's locale is.
    /// Returns the exit code and stderr text; launch failure (missing tool / no permission) throws external.
    func runTool(_ toolPath: String, _ arguments: [String], cwd: URL? = nil,
                 stdoutTo: FileHandle? = nil, captureStdout: Int? = nil,
                 utf8Locale: Bool = false) async throws -> ProcessResult {
        guard FileManager.default.isExecutableFile(atPath: toolPath) else {
            throw ArchiveError(.external, "System tool missing:\(toolPath)", path: toolPath)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: toolPath)
        process.arguments = arguments
        if let cwd { process.currentDirectoryURL = cwd }
        if utf8Locale { process.environment = Self.utf8Environment }
        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = stdoutTo ?? FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let errors = PipeDrain(errPipe)
        let outPipe = captureStdout == nil ? nil : Pipe()
        let output = outPipe.map { PipeDrain($0, limit: captureStdout ?? 0) }
        if let outPipe { process.standardOutput = outPipe }

        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ProcessResult, any Error>) in
                process.terminationHandler = { proc in
                    let text = String(decoding: errors.wait(), as: UTF8.self)
                    cont.resume(returning: ProcessResult(status: proc.terminationStatus, stderr: text,
                                                         stdout: output?.wait() ?? Data(),
                                                         stdoutOverflowed: output?.waitForOverflow() ?? false))
                }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    try? errPipe.fileHandleForWriting.close()   // ends the drain; the child never started
                    try? outPipe?.fileHandleForWriting.close()
                    cont.resume(throwing: ArchiveError(.external,
                        "Could not launch tool\(toolPath): \(error.localizedDescription)", path: toolPath))
                }
            }
        } onCancel: {
            // Cooperative cancellation: SIGTERM the child; terminationHandler still fires so the continuation resumes,
            // and the caller then checks Task.isCancelled → cleans up partial output and throws CancellationError.
            if process.isRunning { process.terminate() }
        }
    }

    static var utf8Environment: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "en_US.UTF-8"
        return environment
    }

    /// stderr summary (first non-empty line, truncated, carried by external errors)
    static func stderrSummary(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
        let s = String(line ?? "").trimmingCharacters(in: .whitespaces)
        return s.count > 200 ? String(s.prefix(200)) + "…" : s
    }
}
