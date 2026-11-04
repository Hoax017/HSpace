import Foundation
import NSpaceContracts

// Private concern: physical implementation of compress / extract.
// Key design, the "staging directory" landing: all output is first written to a hidden staging directory inside the target directory (same volume → atomic rename),
// and moved to its final location on success; cancel or error just deletes the staging directory, so nothing half-finished is left (per the hard rule "cancel cleans up partial output").

extension ArchiveEngineNode {

    // MARK: Compress

    func compress(_ spec: OperationSpec, context: NodeContext, started: Date) async throws -> OperationReceipt {
        let fm = FileManager.default
        guard !spec.sources.isEmpty else {
            throw ArchiveError(.logic, "compress requires at least one source")
        }
        for src in spec.sources where !fm.fileExists(atPath: src.path) {
            throw ArchiveError(.external, "Source not found:\(src.lastPathComponent)", path: src.path)
        }
        let options = spec.archiveOptions ?? ArchiveOptions()
        let isTarGz = options.format.lowercased() == "tar.gz"
        let ext = isTarGz ? "tar.gz" : "zip"

        // All selected items share one parent directory (a file manager selection always comes from a single directory), used as the zip/tar relative root
        let sourcesParent = spec.sources[0].deletingLastPathComponent()
        let outputDir = spec.destination ?? sourcesParent
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: outputDir.path, isDirectory: &isDir), isDir.boolValue else {
            throw ArchiveError(.external, "Output folder unavailable:\(outputDir.lastPathComponent)", path: outputDir.path)
        }

        // Archive base name: explicit newName first; single source uses its extensionless name; multiple sources use the common parent's name (falling back to Archive)
        let baseName: String
        if let n = spec.newName, !n.isEmpty {
            baseName = n
        } else if spec.sources.count == 1 {
            baseName = spec.sources[0].deletingPathExtension().lastPathComponent
        } else {
            let parentName = sourcesParent.lastPathComponent
            baseName = (parentName.isEmpty || parentName == "/") ? "Archive" : parentName
        }
        let finalName = uniqueArchiveName(base: baseName, ext: ext, in: outputDir)

        let inputBytes = spec.sources.reduce(Int64(0)) { $0 + Self.treeSize($1) }
        context.report(.scanTotals(files: 1, bytes: inputBytes))
        context.report(.progress(filesDone: 0, bytesDone: 0, currentPath: finalName))

        // Staging directory (hidden inside the target directory, same volume); output lands here first, then moves out atomically on success
        let staging = outputDir.appendingPathComponent(".nspace-archive-\(UUID().uuidString)")
        try Self.makeDir(staging)
        defer { try? fm.removeItem(at: staging) }
        let stagedArchive = staging.appendingPathComponent(finalName)

        let names = spec.sources.map(\.lastPathComponent)
        do {
            if isTarGz {
                // tar has no built-in encryption: the password is ignored (noted in Contract)
                try await runArchiveTool(Tools.tar,
                    ["-czf", stagedArchive.path, "-C", sourcesParent.path] + names)
            } else {
                var args = ["-r", "-q"]
                if let pw = options.password, !pw.isEmpty { args += ["-P", pw] }  // ZipCrypto weak encryption
                args += [stagedArchive.path] + names
                // cwd = common parent → relative paths inside the archive (no absolute prefix)
                try await runArchiveTool(Tools.zip, args, cwd: sourcesParent)
            }
        } catch is CancellationError {
            throw CancellationError()   // defer cleans up the staging directory (including zip's zi* temp files); the final name never appeared
        }

        // Success: move the archive to its final location (re-check the unique name before moving, in case something concurrent took it)
        let landedName = uniqueArchiveName(base: baseName, ext: ext, in: outputDir)
        let landed = outputDir.appendingPathComponent(landedName)
        do {
            try fm.moveItem(at: stagedArchive, to: landed)
        } catch {
            throw ArchiveError(.external, "Could not save archive:\(error.localizedDescription)", path: landed.path)
        }
        // Progress uses "input bytes processed" as numerator and denominator (Process has no fine granularity, so it reaches 100% after compression); the archive itself is in createdURLs
        context.report(.progress(filesDone: 1, bytesDone: inputBytes, currentPath: landedName))
        return OperationReceipt(id: context.operationID, filesDone: 1, bytesDone: inputBytes,
                                duration: Date().timeIntervalSince(started), createdURLs: [landed])
    }

    // MARK: Extract

    func extract(_ spec: OperationSpec, context: NodeContext, started: Date) async throws -> OperationReceipt {
        let fm = FileManager.default
        guard !spec.sources.isEmpty else {
            throw ArchiveError(.logic, "extract requires at least one source")
        }
        let options = spec.archiveOptions ?? ArchiveOptions()

        // Pre-check: all sources exist and have a recognized format (otherwise logic: the caller should not dispatch unsupported types)
        for src in spec.sources {
            guard fm.fileExists(atPath: src.path) else {
                throw ArchiveError(.external, "Archive not found:\(src.lastPathComponent)", path: src.path)
            }
            guard ArchiveFormat.detect(src) != nil else {
                throw ArchiveError(.logic, "Unrecognized archive format:\(src.lastPathComponent)", path: src.path)
            }
        }

        let totalBytes = spec.sources.reduce(Int64(0)) { $0 + Self.fileSize($1) }
        context.report(.scanTotals(files: spec.sources.count, bytes: totalBytes))

        var created: [URL] = []
        var done = 0
        var bytesDone: Int64 = 0
        for src in spec.sources {
            context.report(.progress(filesDone: done, bytesDone: bytesDone, currentPath: src.lastPathComponent))
            let landed = try await extractOne(src, options: options)
            created.append(contentsOf: landed)
            done += 1
            bytesDone += Self.fileSize(src)
            context.report(.progress(filesDone: done, bytesDone: bytesDone, currentPath: src.lastPathComponent))
        }
        return OperationReceipt(id: context.operationID, filesDone: done, bytesDone: bytesDone,
                                duration: Date().timeIntervalSince(started), createdURLs: created)
    }

    /// Extracts one archive and returns the landed top-level URLs (for UI selection). The staging directory ensures cancel or error leaves nothing half-finished.
    private func extractOne(_ archive: URL, options: ArchiveOptions) async throws -> [URL] {
        let fm = FileManager.default
        guard let format = ArchiveFormat.detect(archive) else {
            throw ArchiveError(.logic, "Unrecognized archive format:\(archive.lastPathComponent)", path: archive.path)
        }
        let targetBaseDir = options.extractInto ?? archive.deletingLastPathComponent()
        try Self.makeDir(targetBaseDir)  // extractInto may not exist yet

        let staging = targetBaseDir.appendingPathComponent(".nspace-extract-\(UUID().uuidString)")
        try Self.makeDir(staging)
        var stagingAlive = true
        defer { if stagingAlive { try? fm.removeItem(at: staging) } }

        // Land in the staging directory
        do {
            switch format {
            case .zip:
                var args = ["-o", "-q"]
                if let pw = options.password, !pw.isEmpty { args += ["-P", pw] }
                args += [archive.path, "-d", staging.path]
                try await runArchiveTool(Tools.unzip, args)
            case .tarGz:
                try await runArchiveTool(Tools.tar, ["-xzf", archive.path, "-C", staging.path])
            case .tarBz2:
                try await runArchiveTool(Tools.tar, ["-xjf", archive.path, "-C", staging.path])
            case .tarXz:
                try await runArchiveTool(Tools.tar, ["-xJf", archive.path, "-C", staging.path])
            case .tar:
                try await runArchiveTool(Tools.tar, ["-xf", archive.path, "-C", staging.path])
            case .gzip, .bzip2, .xz:
                try await extractSingleStream(archive, format: format, into: staging)
            }
        } catch is CancellationError {
            throw CancellationError()   // defer cleans up the staging directory
        }

        // Top-level entries inside staging = what was really extracted (more reliable than a pre-read listing)
        let children = (try? fm.contentsOfDirectory(at: staging,
            includingPropertiesForKeys: nil, options: [])) ?? []
        let topCount = children.count

        var landed: [URL] = []
        if options.createWrapper && topCount > 1 {
            // Wrapper semantics: more than one top-level entry → create a same-named wrapper folder first (by renaming the whole staging directory to the wrapper)
            let stem = Self.archiveStemName(archive, format: format)
            let wrapperName = uniqueArchiveName(base: stem, ext: "", in: targetBaseDir)
            let wrapper = targetBaseDir.appendingPathComponent(wrapperName)
            try fm.moveItem(at: staging, to: wrapper)
            stagingAlive = false   // staging was renamed to the wrapper, so defer no longer deletes it
            landed = [wrapper]
        } else {
            // Only one entry (or no wrapper wanted) → skip the wrapper and move entries into the target directory one by one (same name overwrites, matching unzip -o semantics)
            for child in children {
                let dest = targetBaseDir.appendingPathComponent(child.lastPathComponent)
                if fm.fileExists(atPath: dest.path) { try? fm.removeItem(at: dest) }
                try fm.moveItem(at: child, to: dest)
                landed.append(dest)
            }
        }
        return landed
    }

    /// Single-stream compression (.gz/.bz2/.xz/.Z): extracts to a single output file inside staging (stdout redirected)
    private func extractSingleStream(_ archive: URL, format: ArchiveFormat, into staging: URL) async throws {
        let fm = FileManager.default
        let outName = ArchiveFormat.singleStreamOutputName(for: archive)
        let outURL = staging.appendingPathComponent(outName)
        guard fm.createFile(atPath: outURL.path, contents: Data()) else {
            throw ArchiveError(.external, "Could not create extraction output:\(outName)", path: outURL.path)
        }
        let handle = try FileHandle(forWritingTo: outURL)
        defer { try? handle.close() }
        switch format {
        case .gzip: try await runArchiveTool(Tools.gunzip, ["-c", archive.path], stdoutTo: handle)
        case .bzip2: try await runArchiveTool(Tools.bunzip2, ["-c", archive.path], stdoutTo: handle)
        case .xz: try await runArchiveTool(Tools.xz, ["-dc", archive.path], stdoutTo: handle)
        default: break
        }
    }

    // MARK: Tool invocation (exit code classification)

    /// Runs an archive tool and classifies its exit code: 0 = success; cancelled = CancellationError; non-zero = external (with stderr summary)
    private func runArchiveTool(_ tool: String, _ args: [String], cwd: URL? = nil,
                               stdoutTo: FileHandle? = nil) async throws {
        let result = try await runTool(tool, args, cwd: cwd, stdoutTo: stdoutTo)
        if Task.isCancelled { throw CancellationError() }
        if result.status != 0 {
            let summary = Self.stderrSummary(result.stderr)
            let tail = summary.isEmpty ? "exit code\(result.status)" : summary
            throw ArchiveError(.external, "\(URL(fileURLWithPath: tool).lastPathComponent) failed:\(tail)")
        }
    }

    // MARK: Utilities

    static func makeDir(_ url: URL) throws {
        do { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        catch { throw ArchiveError(.external, "Could not create folder:\(url.lastPathComponent)", path: url.path) }
    }

    /// Size of one file in bytes (0 on failure)
    static func fileSize(_ url: URL) -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? Int64) ?? 0
    }

    /// Recursive size in bytes (compression progress denominator; 0 on failure, decorative, must not hurt the main path)
    static func treeSize(_ url: URL) -> Int64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue {
            return ((try? fm.attributesOfItem(atPath: url.path)[.size]) as? Int64) ?? 0
        }
        var total: Int64 = 0
        if let e = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) {
            for case let f as URL in e {
                let v = try? f.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                if v?.isRegularFile == true { total += Int64(v?.fileSize ?? 0) }
            }
        }
        return total
    }

    /// Archive "stem" (archive suffix removed, original case kept), used to name wrapper folders
    static func archiveStemName(_ url: URL, format: ArchiveFormat) -> String {
        let name = url.lastPathComponent
        let lower = name.lowercased()
        let suffixes: [String]
        switch format {
        case .zip: suffixes = [".zip"]
        case .tarGz: suffixes = [".tar.gz", ".tgz"]
        case .tarBz2: suffixes = [".tar.bz2", ".tbz2", ".tbz"]
        case .tarXz: suffixes = [".tar.xz", ".txz"]
        case .tar: suffixes = [".tar"]
        case .gzip: suffixes = [".gz", ".z"]
        case .bzip2: suffixes = [".bz2"]
        case .xz: suffixes = [".xz"]
        }
        for s in suffixes where lower.hasSuffix(s) {
            return String(name.dropLast(s.count))
        }
        return name
    }
}
