import Foundation
import HSpaceContracts

// Private concern: physical Process driver: launches system tools, captures stderr while they run, cooperative cancellation (terminate).
// Process.run()/waitUntilExit() block, so terminationHandler + CheckedContinuation make this non-blocking,
// staying off the Swift concurrency cooperative pool (same spirit as Transfer's ioQueue).

struct ProcessResult {
    let status: Int32
    let stderr: String
}

/// Reads a pipe from the moment it is created. A pipe holds about 64 KB, so a child writing more
/// would block forever if the pipe were only read after the child exits.
private final class PipeDrain: @unchecked Sendable {
    private let done = DispatchGroup()
    private var data = Data()   // written before done.leave(), read only after done.wait()

    init(_ pipe: Pipe) {
        let reader = pipe.fileHandleForReading
        done.enter()
        DispatchQueue.global(qos: .utility).async { [self] in
            data = (try? reader.readToEnd()) ?? Data()   // diagnostics only
            done.leave()
        }
    }

    func wait() -> Data {
        done.wait()
        return data
    }
}

extension ArchiveEngineNode {

    /// Runs one system tool until it exits; supports cancellation (outer Task cancelled → SIGTERM to the child).
    /// - stdoutTo: if given, the child's stdout goes to this file handle (used to redirect gunzip -c output).
    /// Returns the exit code and stderr text; launch failure (missing tool / no permission) throws external.
    func runTool(_ toolPath: String, _ arguments: [String], cwd: URL? = nil,
                 stdoutTo: FileHandle? = nil) async throws -> ProcessResult {
        guard FileManager.default.isExecutableFile(atPath: toolPath) else {
            throw ArchiveError(.external, "System tool missing:\(toolPath)", path: toolPath)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: toolPath)
        process.arguments = arguments
        if let cwd { process.currentDirectoryURL = cwd }
        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = stdoutTo ?? FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let errors = PipeDrain(errPipe)

        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ProcessResult, any Error>) in
                process.terminationHandler = { proc in
                    let text = String(decoding: errors.wait(), as: UTF8.self)
                    cont.resume(returning: ProcessResult(status: proc.terminationStatus, stderr: text))
                }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    try? errPipe.fileHandleForWriting.close()   // ends the drain; the child never started
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

    /// stderr summary (first non-empty line, truncated, carried by external errors)
    static func stderrSummary(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
        let s = String(line ?? "").trimmingCharacters(in: .whitespaces)
        return s.count > 200 ? String(s.prefix(200)) + "…" : s
    }
}
