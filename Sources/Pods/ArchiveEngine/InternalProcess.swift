import Foundation
import HSpaceContracts

// Private concern: physical Process driver: launches system tools, captures stderr, cooperative cancellation (terminate).
// Process.run()/waitUntilExit() block, so terminationHandler + CheckedContinuation make this non-blocking,
// staying off the Swift concurrency cooperative pool (same spirit as Transfer's ioQueue).

struct ProcessResult {
    let status: Int32
    let stderr: String
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

        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ProcessResult, any Error>) in
                process.terminationHandler = { proc in
                    let errData = (try? errPipe.fileHandleForReading.readToEnd()) ?? Data()
                    let text = String(decoding: errData, as: UTF8.self)
                    cont.resume(returning: ProcessResult(status: proc.terminationStatus, stderr: text))
                }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
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

    /// Runs a tool and collects its stdout as text (for listing archive entries: unzip -Z1 / tar -tf)
    func runToolCapturingStdout(_ toolPath: String, _ arguments: [String]) async throws -> (result: ProcessResult, stdout: String) {
        guard FileManager.default.isExecutableFile(atPath: toolPath) else {
            throw ArchiveError(.external, "System tool missing:\(toolPath)", path: toolPath)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: toolPath)
        process.arguments = arguments
        let outPipe = Pipe(); let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(ProcessResult, String), any Error>) in
                process.terminationHandler = { proc in
                    let outData = (try? outPipe.fileHandleForReading.readToEnd()) ?? Data()
                    let errData = (try? errPipe.fileHandleForReading.readToEnd()) ?? Data()
                    let outText = String(decoding: outData, as: UTF8.self)
                    let errText = String(decoding: errData, as: UTF8.self)
                    cont.resume(returning: (ProcessResult(status: proc.terminationStatus, stderr: errText), outText))
                }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    cont.resume(throwing: ArchiveError(.external,
                        "Could not launch tool\(toolPath): \(error.localizedDescription)", path: toolPath))
                }
            }
        } onCancel: {
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
