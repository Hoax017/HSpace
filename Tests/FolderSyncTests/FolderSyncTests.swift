import Foundation
import FolderSync
import HSpaceTestSupport
import Testing

private final class Fixture {
    let dir: URL
    let left: URL
    let right: URL

    init() throws {
        dir = try FaultFixture.tempDir("hspace-sync")
        left = dir.appendingPathComponent("left")
        right = dir.appendingPathComponent("right")
        for folder in [left, right] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
    }

    deinit { FaultFixture.remove(dir) }

    /// Writes a file, creating its folders, with a fixed modification date
    @discardableResult
    func write(_ root: URL, _ path: String, _ text: String = "text", age: TimeInterval = 1000) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FaultFixture.write(Data(text.utf8), to: url)
        try setAge(url, age)
        return url
    }

    func setAge(_ url: URL, _ age: TimeInterval) throws {
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000 - age)], ofItemAtPath: url.path)
    }

    func plan(_ options: SyncOptions = SyncOptions()) throws -> SyncPlan {
        try SyncPlanner.plan(left: left, right: right, options: options)
    }
}

private func paths(_ plan: SyncPlan, _ kind: SyncAction.Kind) -> [String] {
    plan.actions.filter { $0.kind == kind }.map(\.relativePath).sorted()
}

/// Applies actions with plain file calls and counts them, so the pod is tested without the kernel.
private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []
    var failCopy = false
    var cancelCopy = false
    let trashFolder: URL

    init(trashFolder: URL) throws {
        self.trashFolder = trashFolder
        try FileManager.default.createDirectory(at: trashFolder, withIntermediateDirectories: true)
    }

    var calls: [String] { lock.withLock { log } }
    private func note(_ text: String) { lock.withLock { log.append(text) } }

    var driver: SyncDriver {
        SyncDriver(
            copy: { sources, folder in
                self.note("copy")
                if self.cancelCopy { throw CancellationError() }
                if self.failCopy { throw POSIXError(.ENOSPC) }
                for source in sources {
                    try FileManager.default.copyItem(at: source, to: folder.appendingPathComponent(source.lastPathComponent))
                }
            },
            trash: { items in
                self.note("trash")
                for item in items {
                    try FileManager.default.moveItem(at: item, to: self.trashFolder.appendingPathComponent(UUID().uuidString))
                }
            },
            makeFolder: { name, parent in
                self.note("folder")
                try FileManager.default.createDirectory(at: parent.appendingPathComponent(name), withIntermediateDirectories: false)
            })
    }
}

@Suite struct PlanningTests {
    @Test func newChangedAndIdenticalFiles() throws {
        let f = try Fixture()
        try f.write(f.left, "new.txt")
        try f.write(f.left, "changed.txt", "longer text")
        try f.write(f.right, "changed.txt", "short")
        try f.write(f.left, "same.txt")
        try f.write(f.right, "same.txt")
        let plan = try f.plan()
        #expect(paths(plan, .copy) == ["new.txt"])
        #expect(paths(plan, .replace) == ["changed.txt"])
        #expect(plan.identicalCount == 1)
    }

    @Test func planningWritesNothing() throws {
        let f = try Fixture()
        try f.write(f.left, "a/b.txt")
        try f.write(f.right, "extra.txt")
        let before = try FileManager.default.subpathsOfDirectory(atPath: f.dir.path).sorted()
        _ = try f.plan(SyncOptions(deleteExtras: true))
        #expect(try FileManager.default.subpathsOfDirectory(atPath: f.dir.path).sorted() == before)
    }

    @Test func aMissingFolderIsOneAction() throws {
        let f = try Fixture()
        try f.write(f.left, "tree/a/1.txt", "12345")
        try f.write(f.left, "tree/2.txt", "123")
        let plan = try f.plan()
        #expect(paths(plan, .copy) == ["tree"])
        #expect(plan.bytesToCopy == 8)
    }

    @Test func aPartlyFilteredFolderGoesPieceByPiece() throws {
        let f = try Fixture()
        try f.write(f.left, "tree/keep.txt")
        try f.write(f.left, "tree/skip.log")
        let plan = try f.plan(SyncOptions(filter: SyncFilter(exclude: ["*.log"])))
        #expect(paths(plan, .createFolder) == ["tree"])
        #expect(paths(plan, .copy) == ["tree/keep.txt"])
    }

    @Test func foldersComeBeforeTheirFiles() throws {
        let f = try Fixture()
        try f.write(f.left, "a/b/keep.txt")
        try f.write(f.left, "a/b/skip.log")
        let plan = try f.plan(SyncOptions(filter: SyncFilter(exclude: ["*.log"])))
        #expect(plan.actions.map(\.relativePath) == ["a", "a/b", "a/b/keep.txt"])
    }

    @Test func directionDecidesWhoReceives() throws {
        let f = try Fixture()
        try f.write(f.left, "l.txt")
        try f.write(f.right, "r.txt")
        #expect(paths(try f.plan(SyncOptions(direction: .leftToRight)), .copy) == ["l.txt"])
        let reverse = try f.plan(SyncOptions(direction: .rightToLeft))
        #expect(paths(reverse, .copy) == ["r.txt"])
        #expect(reverse.actions[0].towardRight == false)
        #expect(paths(try f.plan(SyncOptions(direction: .twoWay)), .copy) == ["l.txt", "r.txt"])
    }

    @Test func extrasStayUnlessAsked() throws {
        let f = try Fixture()
        try f.write(f.right, "extra.txt")
        let kept = try f.plan()
        #expect(kept.deletes.isEmpty && kept.extrasKept == 1)
        #expect(paths(try f.plan(SyncOptions(deleteExtras: true)), .delete) == ["extra.txt"])
    }

    @Test func twoWayNeverDeletes() throws {
        let f = try Fixture()
        try f.write(f.right, "extra.txt")
        #expect(try f.plan(SyncOptions(direction: .twoWay, deleteExtras: true)).deletes.isEmpty)
    }

    @Test func twoWayTakesTheNewerAndSkipsATie() throws {
        let f = try Fixture()
        try f.write(f.left, "new-left.txt", "aa", age: 10)
        try f.write(f.right, "new-left.txt", "b", age: 500)
        try f.write(f.left, "new-right.txt", "b", age: 500)
        try f.write(f.right, "new-right.txt", "aa", age: 10)
        try f.write(f.left, "tie.txt", "aa", age: 10)
        try f.write(f.right, "tie.txt", "b", age: 10)
        let plan = try f.plan(SyncOptions(direction: .twoWay))
        let toRight = plan.actions.first { $0.relativePath == "new-left.txt" }
        let toLeft = plan.actions.first { $0.relativePath == "new-right.txt" }
        #expect(toRight?.towardRight == true && toRight?.kind == .replace)
        #expect(toLeft?.towardRight == false && toLeft?.kind == .replace)
        #expect(plan.actions.first { $0.relativePath == "tie.txt" }?.kind == .skip(.undecided))
    }

    @Test func aReplaceOverANewerFileIsFlagged() throws {
        let f = try Fixture()
        try f.write(f.left, "a.txt", "old!", age: 500)
        try f.write(f.right, "a.txt", "new", age: 10)
        #expect(try f.plan().actions[0].targetIsNewer)
    }

    @Test func aTwoSecondDateDifferenceIsTheSame() throws {
        let f = try Fixture()
        try f.write(f.left, "a.txt", age: 100)
        try f.write(f.right, "a.txt", age: 101)
        #expect(try f.plan().identicalCount == 1)
    }

    @Test func contentComparisonIgnoresDates() throws {
        let f = try Fixture()
        try f.write(f.left, "same.txt", "abcd", age: 500)
        try f.write(f.right, "same.txt", "abcd", age: 10)
        try f.write(f.left, "diff.txt", "abcd", age: 10)
        try f.write(f.right, "diff.txt", "abce", age: 10)
        let contents = try f.plan(SyncOptions(comparison: .contents))
        #expect(contents.identicalCount == 1)
        #expect(paths(contents, .replace) == ["diff.txt"])
        #expect(try f.plan().identicalCount == 1)
    }

    @Test func aFileAgainstAFolderIsSkipped() throws {
        let f = try Fixture()
        try f.write(f.left, "name")
        try f.write(f.right, "name/inside.txt")
        let plan = try f.plan(SyncOptions(deleteExtras: true))
        #expect(plan.actions.map(\.kind) == [.skip(.typeMismatch)])
    }

    @Test func linksAreComparedAsLinksAndNeverFollowed() throws {
        let f = try Fixture()
        let leftLink = f.left.appendingPathComponent("link")
        let rightLink = f.right.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(atPath: leftLink.path, withDestinationPath: "/one")
        try FileManager.default.createSymbolicLink(atPath: rightLink.path, withDestinationPath: "/one")
        #expect(try f.plan().identicalCount == 1)
        try FileManager.default.removeItem(at: rightLink)
        try FileManager.default.createSymbolicLink(atPath: rightLink.path, withDestinationPath: "/two")
        #expect(paths(try f.plan(), .replace) == ["link"])
    }

    @Test func aNameDifferingOnlyByCaseIsOneItem() throws {
        let f = try Fixture()
        try f.write(f.left, "Report.txt")
        try f.write(f.right, "report.txt")
        let plan = try f.plan(SyncOptions(deleteExtras: true))
        #expect(plan.identicalCount == 1)
        #expect(plan.actions.isEmpty)
    }

    @Test func decomposedNamesMatch() throws {
        let f = try Fixture()
        try f.write(f.left, "caf\u{E9}.txt")
        try f.write(f.right, "cafe\u{301}.txt")
        #expect(try f.plan().actions.isEmpty)
    }

    @Test func aHiddenFilterSkipsBothSides() throws {
        let f = try Fixture()
        try f.write(f.left, ".secret")
        try f.write(f.right, ".other")
        let plan = try f.plan(SyncOptions(deleteExtras: true, filter: SyncFilter(skipHidden: true)))
        #expect(plan.actions.isEmpty && plan.extrasKept == 0)
    }

    @Test func includePatternsNarrowFilesOnly() throws {
        let f = try Fixture()
        try f.write(f.left, "photos/a.JPG")
        try f.write(f.left, "photos/b.txt")
        let plan = try f.plan(SyncOptions(filter: SyncFilter(include: ["*.jpg"])))
        #expect(paths(plan, .copy) == ["photos/a.JPG"])
    }

    @Test func aPathPatternMatchesTheRelativePath() throws {
        let f = try Fixture()
        try f.write(f.left, "build/out.txt")
        try f.write(f.left, "src/out.txt")
        let plan = try f.plan(SyncOptions(filter: SyncFilter(exclude: ["build/*"])))
        #expect(paths(plan, .copy) == ["src"])
        #expect(paths(plan, .createFolder) == ["build"])
    }

    @Test func dsStoreIsLeftOutByDefault() throws {
        let f = try Fixture()
        try f.write(f.left, ".DS_Store")
        #expect(try f.plan().actions.isEmpty)
    }
}

@Suite struct DeleteSafetyTests {
    @Test func anExcludedItemIsNotDeleted() throws {
        let f = try Fixture()
        try f.write(f.right, "extra/keep.log")
        try f.write(f.right, "extra/gone.txt")
        let plan = try f.plan(SyncOptions(deleteExtras: true, filter: SyncFilter(exclude: ["*.log"])))
        #expect(paths(plan, .delete) == ["extra/gone.txt"])
    }

    @Test func anUnreadableFolderRemovesEveryDelete() async throws {
        let f = try Fixture()
        try f.write(f.right, "extra.txt")
        let locked = f.left.appendingPathComponent("locked")
        try f.write(f.left, "locked/inside.txt")
        try f.write(f.right, "locked/inside.txt")
        let plan = try await FaultFixture.withUnreadable(locked) { try f.plan(SyncOptions(deleteExtras: true)) }
        #expect(plan.deletes.isEmpty)
        #expect(plan.problems.count == 1)
        #expect(plan.actions.map(\.kind) == [.skip(.scanIncomplete)])
    }

    @Test func anEmptiedSourceRaisesTheAlarm() throws {
        let f = try Fixture()
        try f.write(f.right, "everything.txt")
        #expect(try f.plan(SyncOptions(deleteExtras: true)).wouldEmptyReceiver)
    }

    @Test func aNormalMirrorDoesNotRaiseTheAlarm() throws {
        let f = try Fixture()
        try f.write(f.left, "a.txt")
        try f.write(f.right, "extra.txt")
        #expect(try !f.plan(SyncOptions(deleteExtras: true)).wouldEmptyReceiver)
    }

    @Test func aMissingOrNestedFolderIsRefused() throws {
        let f = try Fixture()
        let missing = f.dir.appendingPathComponent("gone")
        #expect(throws: SyncError.self) { try SyncPlanner.plan(left: f.left, right: missing, options: SyncOptions()) }
        #expect(throws: SyncError.self) { try SyncPlanner.plan(left: f.left, right: f.left, options: SyncOptions()) }
        let nested = f.left.appendingPathComponent("inner")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        #expect(throws: SyncError.self) { try SyncPlanner.plan(left: f.left, right: nested, options: SyncOptions()) }
        #expect(throws: SyncError.self) { try SyncPlanner.plan(left: nested, right: f.left, options: SyncOptions()) }
    }

    @Test func aFileAsARootIsRefused() throws {
        let f = try Fixture()
        let file = try f.write(f.dir, "file.txt")
        #expect(throws: SyncError.self) { try SyncPlanner.plan(left: file, right: f.right, options: SyncOptions()) }
    }

    @Test func cancellingStopsTheScan() async throws {
        let f = try Fixture()
        try f.write(f.left, "a.txt")
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try SyncPlanner.plan(left: f.left, right: f.right, options: SyncOptions())
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }
}

@Suite struct ExecutionTests {
    private func snapshot(_ url: URL) throws -> [String] { try FileManager.default.subpathsOfDirectory(atPath: url.path).sorted() }

    private func mirrorFixture() throws -> Fixture {
        let f = try Fixture()
        try f.write(f.left, "new.txt")
        try f.write(f.left, "changed.txt", "longer")
        try f.write(f.right, "changed.txt", "old")
        try f.write(f.right, "extra.txt")
        return f
    }

    @Test func aDryRunWritesNothingAndReportsAll() async throws {
        let f = try mirrorFixture()
        let recorder = try Recorder(trashFolder: f.dir.appendingPathComponent("trash"))
        let plan = try f.plan(SyncOptions(deleteExtras: true))
        let before = try snapshot(f.left) + snapshot(f.right)
        let report = await SyncExecutor.run(plan, mode: .dryRun, driver: recorder.driver)
        #expect(try snapshot(f.left) + snapshot(f.right) == before)
        #expect(recorder.calls.isEmpty)
        #expect(report.isDryRun)
        #expect(report.copied == 1 && report.replaced == 1 && report.deleted == 1)
    }

    @Test func aDryRunReportsAnItemThatChanged() async throws {
        let f = try mirrorFixture()
        let recorder = try Recorder(trashFolder: f.dir.appendingPathComponent("trash"))
        let plan = try f.plan(SyncOptions(deleteExtras: true))
        try f.write(f.right, "extra.txt", "edited since")
        let report = await SyncExecutor.run(plan, mode: .dryRun, driver: recorder.driver)
        #expect(report.changedSincePreview == ["extra.txt"])
        #expect(report.deleted == 0)
    }

    @Test func applyingMakesTheFoldersMatch() async throws {
        let f = try mirrorFixture()
        let recorder = try Recorder(trashFolder: f.dir.appendingPathComponent("trash"))
        let options = SyncOptions(deleteExtras: true)
        let report = await SyncExecutor.run(try f.plan(options), mode: .apply(confirmedDeletes: true), driver: recorder.driver)
        #expect(report.isClean)
        #expect(try snapshot(f.left) == snapshot(f.right))
        #expect(try String(contentsOf: f.right.appendingPathComponent("changed.txt"), encoding: .utf8) == "longer")
        #expect(try !f.plan(options).hasWork)
    }

    @Test func noDeleteWithoutConfirmation() async throws {
        let f = try mirrorFixture()
        let recorder = try Recorder(trashFolder: f.dir.appendingPathComponent("trash"))
        let plan = try f.plan(SyncOptions(deleteExtras: true))
        let report = await SyncExecutor.run(plan, mode: .apply(confirmedDeletes: false), driver: recorder.driver)
        #expect(FileManager.default.fileExists(atPath: f.right.appendingPathComponent("extra.txt").path))
        #expect(report.deleted == 0 && report.unconfirmedDeletes == 1)
        #expect(report.copied == 1)
    }

    @Test func deletesAndReplacedItemsGoToTheTrash() async throws {
        let f = try mirrorFixture()
        let trash = f.dir.appendingPathComponent("trash")
        let recorder = try Recorder(trashFolder: trash)
        _ = await SyncExecutor.run(try f.plan(SyncOptions(deleteExtras: true)), mode: .apply(confirmedDeletes: true), driver: recorder.driver)
        #expect(try FileManager.default.contentsOfDirectory(atPath: trash.path).count == 2)
    }

    @Test func aFailedCopyKeepsTheDeletesFromRunning() async throws {
        let f = try mirrorFixture()
        let recorder = try Recorder(trashFolder: f.dir.appendingPathComponent("trash"))
        recorder.failCopy = true
        let report = await SyncExecutor.run(try f.plan(SyncOptions(deleteExtras: true)), mode: .apply(confirmedDeletes: true), driver: recorder.driver)
        #expect(report.stoppedEarly)
        #expect(report.failures.count == 1)
        #expect(report.deleted == 0)
        #expect(FileManager.default.fileExists(atPath: f.right.appendingPathComponent("extra.txt").path))
    }

    @Test func cancellingStopsAndSaysSo() async throws {
        let f = try mirrorFixture()
        let recorder = try Recorder(trashFolder: f.dir.appendingPathComponent("trash"))
        recorder.cancelCopy = true
        let report = await SyncExecutor.run(try f.plan(SyncOptions(deleteExtras: true)), mode: .apply(confirmedDeletes: true), driver: recorder.driver)
        #expect(report.wasCancelled)
        #expect(!report.isClean)
        #expect(report.deleted == 0)
    }

    @Test func aFileAddedToAFolderPlannedForDeleteSavesIt() async throws {
        let f = try Fixture()
        try f.write(f.right, "old/inside.txt")
        let recorder = try Recorder(trashFolder: f.dir.appendingPathComponent("trash"))
        let plan = try f.plan(SyncOptions(deleteExtras: true))
        #expect(paths(plan, .delete) == ["old"])
        try f.write(f.right, "old/added.txt")
        let report = await SyncExecutor.run(plan, mode: .apply(confirmedDeletes: true), driver: recorder.driver)
        #expect(report.changedSincePreview == ["old"])
        #expect(FileManager.default.fileExists(atPath: f.right.appendingPathComponent("old/added.txt").path))
    }

    @Test func aSourceChangedSincePreviewIsNotCopied() async throws {
        let f = try Fixture()
        try f.write(f.left, "a.txt", "one")
        let recorder = try Recorder(trashFolder: f.dir.appendingPathComponent("trash"))
        let plan = try f.plan()
        try f.write(f.left, "a.txt", "changed")
        let report = await SyncExecutor.run(plan, mode: .apply(confirmedDeletes: false), driver: recorder.driver)
        #expect(report.changedSincePreview == ["a.txt"])
        #expect(!FileManager.default.fileExists(atPath: f.right.appendingPathComponent("a.txt").path))
    }

    @Test func aTargetThatAppearedIsNotOverwritten() async throws {
        let f = try Fixture()
        try f.write(f.left, "a.txt", "mine")
        let recorder = try Recorder(trashFolder: f.dir.appendingPathComponent("trash"))
        let plan = try f.plan()
        try f.write(f.right, "a.txt", "theirs")
        _ = await SyncExecutor.run(plan, mode: .apply(confirmedDeletes: false), driver: recorder.driver)
        #expect(try String(contentsOf: f.right.appendingPathComponent("a.txt"), encoding: .utf8) == "theirs")
    }

    @Test func aReplaceWithAChangedTargetKeepsIt() async throws {
        let f = try mirrorFixture()
        let recorder = try Recorder(trashFolder: f.dir.appendingPathComponent("trash"))
        let plan = try f.plan()
        try f.write(f.right, "changed.txt", "edited")
        let report = await SyncExecutor.run(plan, mode: .apply(confirmedDeletes: false), driver: recorder.driver)
        #expect(report.replaced == 0)
        #expect(try String(contentsOf: f.right.appendingPathComponent("changed.txt"), encoding: .utf8) == "edited")
    }

    @Test func filesOfOneFolderAreOneOperation() async throws {
        let f = try Fixture()
        for index in 0..<5 { try f.write(f.left, "\(index).txt") }
        let recorder = try Recorder(trashFolder: f.dir.appendingPathComponent("trash"))
        let report = await SyncExecutor.run(try f.plan(), mode: .apply(confirmedDeletes: false), driver: recorder.driver)
        #expect(report.copied == 5)
        #expect(recorder.calls == ["copy"])
    }

    @Test func createdFoldersReceiveTheirFiles() async throws {
        let f = try Fixture()
        try f.write(f.left, "a/b/keep.txt")
        try f.write(f.left, "a/b/skip.log")
        let recorder = try Recorder(trashFolder: f.dir.appendingPathComponent("trash"))
        let plan = try f.plan(SyncOptions(filter: SyncFilter(exclude: ["*.log"])))
        let report = await SyncExecutor.run(plan, mode: .apply(confirmedDeletes: false), driver: recorder.driver)
        #expect(report.foldersCreated == 2)
        #expect(try snapshot(f.right) == ["a", "a/b", "a/b/keep.txt"])
    }

    @Test func progressReachesTheTotal() async throws {
        let f = try mirrorFixture()
        let recorder = try Recorder(trashFolder: f.dir.appendingPathComponent("trash"))
        let last = Last()
        _ = await SyncExecutor.run(try f.plan(SyncOptions(deleteExtras: true)), mode: .apply(confirmedDeletes: true),
                                   driver: recorder.driver) { done, total in last.set(done, total) }
        #expect(last.value == [3, 3])
    }
}

private final class Last: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int] = []
    var value: [Int] { lock.withLock { values } }
    func set(_ done: Int, _ total: Int) { lock.withLock { values = [done, total] } }
}

@Suite struct PresetStoreTests {
    @Test func presetsSurviveAndReplaceByName() async throws {
        let dir = try FaultFixture.tempDir("hspace-sync")
        defer { FaultFixture.remove(dir) }
        let store = SyncPresetStore(directory: dir)
        await store.save(SyncPreset(name: "Photos", options: SyncOptions(), left: "/a", right: "/b"))
        await store.save(SyncPreset(name: "photos", options: SyncOptions(direction: .twoWay)))
        let saved = await SyncPresetStore(directory: dir).saved()
        #expect(saved.count == 1)
        #expect(saved[0].options.direction == .twoWay)
    }

    @Test func removeForgets() async throws {
        let dir = try FaultFixture.tempDir("hspace-sync")
        defer { FaultFixture.remove(dir) }
        let store = SyncPresetStore(directory: dir)
        let preset = SyncPreset(name: "One", options: SyncOptions())
        await store.save(preset)
        await store.remove(preset.id)
        #expect(await SyncPresetStore(directory: dir).saved().isEmpty)
    }

    @Test func aDamagedFileIsKeptAside() async throws {
        let dir = try FaultFixture.tempDir("hspace-sync")
        defer { FaultFixture.remove(dir) }
        try FaultFixture.write(Data("nope".utf8), to: dir.appendingPathComponent("sync-presets.json"))
        let store = SyncPresetStore(directory: dir)
        #expect(await store.saved().isEmpty)
        #expect(await store.takeProblem() != nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).contains { $0.contains("corrupt") })
    }

    @Test func aFailedSaveIsReported() async throws {
        let dir = try FaultFixture.tempDir("hspace-sync")
        defer { FaultFixture.remove(dir) }
        let store = SyncPresetStore(directory: dir)
        try await FaultFixture.withReadOnly(dir) {
            await store.save(SyncPreset(name: "One", options: SyncOptions()))
            #expect(await store.takeProblem() != nil)
        }
    }

    @Test func theBuiltInPresetsAreTheThreeShapes() {
        #expect(SyncPresetStore.builtIn.count == 3)
        #expect(SyncPresetStore.builtIn.contains { $0.options.deleteExtras })
        #expect(Set(SyncPresetStore.builtIn.map(\.id)).count == 3)
    }
}
