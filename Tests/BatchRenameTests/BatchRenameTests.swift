import BatchRename
import Foundation
import HSpaceContracts
import HSpaceTestSupport
import Testing

func names(in dir: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
}

func fixture(_ names: [String]) throws -> (dir: URL, urls: [URL]) {
    let dir = try FaultFixture.tempDir("hspace-rename")
    let urls = names.map { dir.appendingPathComponent($0) }
    for url in urls { try FaultFixture.write(Data(url.lastPathComponent.utf8), to: url) }
    return (dir, urls)
}

private func newNames(_ source: [String], _ steps: [RenameStep], now: Date = Date()) throws -> [String] {
    let dir = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
    let items = source.map { RenameItem(url: dir.appendingPathComponent($0)) }
    return try BatchRenamePlanner.plan(items: items, steps: steps, now: now).rows.map(\.newName)
}

@Suite struct ProcessorTests {
    @Test func replaceWorksOnTheStemByDefault() throws {
        let step = RenameStep.replace(ReplaceStep(find: "a", replacement: "x"))
        #expect(try newNames(["banana.a"], [step]) == ["bxnxnx.a"])
    }

    @Test func replaceTreatsTextLiterallyUnlessToldOtherwise() throws {
        let literal = RenameStep.replace(ReplaceStep(find: "(1)", replacement: "$1"))
        #expect(try newNames(["a(1).txt"], [literal]) == ["a$1.txt"])
        let regex = RenameStep.replace(ReplaceStep(find: #"(\d+)-(\d+)"#, replacement: "$2-$1", isRegex: true))
        #expect(try newNames(["10-20.txt"], [regex]) == ["20-10.txt"])
    }

    @Test func replaceHonoursCaseAndFirstMatchOnly() throws {
        let sensitive = RenameStep.replace(ReplaceStep(find: "A", replacement: "x", caseSensitive: true))
        #expect(try newNames(["aA.txt"], [sensitive]) == ["ax.txt"])
        let first = RenameStep.replace(ReplaceStep(find: "a", replacement: "x", firstMatchOnly: true))
        #expect(try newNames(["aaa.txt"], [first]) == ["xaa.txt"])
    }

    @Test func replaceInTheWholeNameCanMoveTheExtension() throws {
        let step = RenameStep.replace(ReplaceStep(find: ".tar.gz", replacement: ".tgz", scope: .wholeName))
        #expect(try newNames(["a.tar.gz"], [step]) == ["a.tgz"])
    }

    @Test func anEmptyFindChangesNothing() throws {
        #expect(try newNames(["a.txt"], [.replace(ReplaceStep(find: "", replacement: "x"))]) == ["a.txt"])
    }

    @Test func anInvalidRegularExpressionIsReported() {
        let step = RenameStep.replace(ReplaceStep(find: "(", replacement: "", isRegex: true))
        #expect(throws: BatchRenameError.self) { try newNames(["a"], [step]) }
    }

    @Test func caseChangesRespectTheirScope() throws {
        #expect(try newNames(["my file.TXT"], [.changeCase(.upper, scope: .stem)]) == ["MY FILE.TXT"])
        #expect(try newNames(["my file.TXT"], [.changeCase(.lower, scope: .fileExtension)]) == ["my file.txt"])
        #expect(try newNames(["my file.txt"], [.changeCase(.title, scope: .stem)]) == ["My File.txt"])
        #expect(try newNames(["MY FILE.txt"], [.changeCase(.sentence, scope: .stem)]) == ["My file.txt"])
    }

    @Test func sequencesNumberInItemOrderWithPadding() throws {
        let step = RenameStep.sequence(SequenceStep(start: 9, increment: 2, width: 3, position: .replaceName))
        #expect(try newNames(["b.txt", "a.txt"], [step]) == ["009.txt", "011.txt"])
    }

    @Test func sequencesCanRestartInEachFolder() throws {
        let items = ["/x/one/a", "/x/one/b", "/x/two/c"].map { RenameItem(url: URL(fileURLWithPath: $0)) }
        let step = RenameStep.sequence(SequenceStep(position: .suffix, separator: "-", restartPerFolder: true))
        let plan = try BatchRenamePlanner.plan(items: items, steps: [step])
        #expect(plan.rows.map(\.newName) == ["a-1", "b-2", "c-1"])
    }

    @Test func insertAndDatePlaceTextAroundTheStem() throws {
        let date = RenameStep.date(DateStep(source: .now, format: "yyyy", position: .prefix, separator: "_"))
        let midYear = Date(timeIntervalSince1970: 86_400 * 500)
        #expect(try newNames(["a.txt"], [date, .insert(text: "!", position: .suffix)], now: midYear) == ["1971_a!.txt"])
    }

    @Test func aMissingDateLeavesTheNameAlone() throws {
        let item = RenameItem(url: URL(fileURLWithPath: "/nonexistent/a.txt"), created: nil)
        let plan = try BatchRenamePlanner.plan(items: [item], steps: [.date(DateStep(source: .created))])
        #expect(plan.rows[0].newName == "a.txt")
    }

    @Test func aFolderHasNoExtensionButAPackageDoes() throws {
        let folder = RenameItem(url: URL(fileURLWithPath: "/nonexistent/v1.2"), isDirectory: true)
        let package = RenameItem(url: URL(fileURLWithPath: "/nonexistent/App.app"), isDirectory: true, isPackage: true)
        let plan = try BatchRenamePlanner.plan(items: [folder, package], steps: [.insert(text: "x", position: .suffix)])
        #expect(plan.rows.map(\.newName) == ["v1.2x", "Appx.app"])
    }

    @Test func aDotfileIsAllStem() throws {
        #expect(try newNames([".bashrc"], [.insert(text: "x", position: .suffix)]) == [".bashrcx"])
    }

    @Test func stepsSurviveCoding() throws {
        let steps: [RenameStep] = [
            .replace(ReplaceStep(find: "a", replacement: "b", isRegex: true)),
            .changeCase(.title, scope: .wholeName),
            .insert(text: "x", position: .prefix),
            .sequence(SequenceStep(width: 4)),
            .date(DateStep(source: .created, format: "yy")),
        ]
        let decoded = try JSONDecoder().decode([RenameStep].self, from: JSONEncoder().encode(steps))
        #expect(decoded == steps)
    }
}

@Suite struct CollisionTests {
    private func status(_ plan: RenamePlan, _ index: Int) -> RenameRowStatus { plan.rows[index].status }

    @Test func aNameTakenOutsideTheBatchBlocksIt() throws {
        let (dir, urls) = try fixture(["a.txt", "b.txt"])
        defer { FaultFixture.remove(dir) }
        let plan = try BatchRenamePlanner.plan(sources: [urls[0]], names: ["b.txt"])
        #expect(status(plan, 0) == .blocked(.existsOnDisk))
        #expect(!plan.canApply)
    }

    @Test func aNameTakenByADanglingLinkBlocksIt() throws {
        let (dir, urls) = try fixture(["a.txt"])
        defer { FaultFixture.remove(dir) }
        try FaultFixture.danglingLink(at: dir.appendingPathComponent("link"))
        let plan = try BatchRenamePlanner.plan(sources: [urls[0]], names: ["link"])
        #expect(status(plan, 0) == .blocked(.existsOnDisk))
    }

    @Test func twoRowsOnOneNameAreBothBlocked() throws {
        let (dir, urls) = try fixture(["a.txt", "b.txt"])
        defer { FaultFixture.remove(dir) }
        let plan = try BatchRenamePlanner.plan(sources: urls, names: ["c.txt", "c.txt"])
        #expect(plan.blockedCount == 2)
        #expect(status(plan, 0) == .blocked(.duplicateInBatch))
    }

    @Test func namesDifferingByCaseCollideOnACaseInsensitiveVolume() throws {
        let (dir, urls) = try fixture(["a.txt", "b.txt"])
        defer { FaultFixture.remove(dir) }
        try #require(FileManager.default.fileExists(atPath: dir.appendingPathComponent("A.TXT").path))
        let plan = try BatchRenamePlanner.plan(sources: urls, names: ["c.txt", "C.TXT"])
        #expect(plan.blockedCount == 2)
    }

    @Test func differentNormalizationsAreTheSameName() throws {
        let (dir, urls) = try fixture(["a.txt", "b.txt"])
        defer { FaultFixture.remove(dir) }
        let plan = try BatchRenamePlanner.plan(sources: urls, names: ["caf\u{E9}.txt", "cafe\u{301}.txt"])
        #expect(plan.blockedCount == 2)
    }

    @Test func aRowCollidingWithAnUnchangedRowIsBlocked() throws {
        let (dir, urls) = try fixture(["a.txt", "b.txt"])
        defer { FaultFixture.remove(dir) }
        let plan = try BatchRenamePlanner.plan(sources: urls, names: ["a.txt", "a.txt"])
        #expect(plan.blockedCount == 2)
    }

    @Test func aNameFreedInTheSameBatchIsFine() throws {
        let (dir, urls) = try fixture(["a.txt", "b.txt"])
        defer { FaultFixture.remove(dir) }
        let plan = try BatchRenamePlanner.plan(sources: urls, names: ["b.txt", "a.txt"])
        #expect(plan.canApply)
        #expect(plan.changeCount == 2)
    }

    @Test func badNamesAreBlocked() throws {
        let (dir, urls) = try fixture(["a.txt"])
        defer { FaultFixture.remove(dir) }
        let cases: [(String, RenameIssue)] = [
            ("", .emptyName), (".", .invalidName), ("..", .invalidName), ("a/b", .invalidName),
            ("a:b", .invalidName), ("a\nb", .invalidName), (String(repeating: "é", count: 128), .nameTooLong),
        ]
        for (name, issue) in cases {
            let plan = try BatchRenamePlanner.plan(sources: urls, names: [name])
            #expect(status(plan, 0) == .blocked(issue), "\(name)")
        }
    }

    @Test func aMissingSourceIsBlocked() throws {
        let dir = try FaultFixture.tempDir("hspace-rename")
        defer { FaultFixture.remove(dir) }
        let plan = try BatchRenamePlanner.plan(sources: [dir.appendingPathComponent("gone")], names: ["x"])
        #expect(status(plan, 0) == .blocked(.sourceMissing))
    }

    @Test func aPlanWithNothingToDoCannotBeApplied() throws {
        let (dir, urls) = try fixture(["a.txt"])
        defer { FaultFixture.remove(dir) }
        let plan = try BatchRenamePlanner.plan(sources: urls, names: ["a.txt"])
        #expect(status(plan, 0) == .unchanged)
        #expect(!plan.canApply)
    }

    @Test func mismatchedNamesAreALogicError() {
        #expect(throws: BatchRenameError.self) {
            try BatchRenamePlanner.plan(sources: [URL(fileURLWithPath: "/a")], names: [])
        }
    }
}

@Suite struct ApplyTests {
    @Test func aBatchLandsAndIsUndoneAsOne() async throws {
        let (dir, urls) = try fixture(["a.txt", "b.txt", "c.txt"])
        defer { FaultFixture.remove(dir) }
        let plan = try BatchRenamePlanner.plan(items: urls.map { RenameItem(url: $0) },
                                               steps: [.sequence(SequenceStep(position: .replaceName))])
        let journal = try await BatchRenamer.apply(plan)
        #expect(try names(in: dir) == ["1.txt", "2.txt", "3.txt"])
        #expect(journal.entries.count == 3)
        let redo = try await BatchRenamer.undo(journal)
        #expect(try names(in: dir) == ["a.txt", "b.txt", "c.txt"])
        _ = try await BatchRenamer.undo(redo)
        #expect(try names(in: dir) == ["1.txt", "2.txt", "3.txt"])
    }

    @Test func swapsAndChainsKeepEachFilesContent() async throws {
        let (dir, urls) = try fixture(["a", "b", "c"])
        defer { FaultFixture.remove(dir) }
        let plan = try BatchRenamePlanner.plan(sources: urls, names: ["b", "c", "d"])
        _ = try await BatchRenamer.apply(plan)
        #expect(try names(in: dir) == ["b", "c", "d"])
        #expect(try String(contentsOf: dir.appendingPathComponent("b"), encoding: .utf8) == "a")
        #expect(try String(contentsOf: dir.appendingPathComponent("d"), encoding: .utf8) == "c")

        let swap = try BatchRenamePlanner.plan(sources: [dir.appendingPathComponent("b"), dir.appendingPathComponent("c")],
                                               names: ["c", "b"])
        let journal = try await BatchRenamer.apply(swap)
        #expect(try String(contentsOf: dir.appendingPathComponent("c"), encoding: .utf8) == "a")
        _ = try await BatchRenamer.undo(journal)
        #expect(try String(contentsOf: dir.appendingPathComponent("b"), encoding: .utf8) == "a")
    }

    @Test func aCaseOnlyRenameLands() async throws {
        let (dir, urls) = try fixture(["photo.jpg"])
        defer { FaultFixture.remove(dir) }
        let plan = try BatchRenamePlanner.plan(items: [RenameItem(url: urls[0])], steps: [.changeCase(.upper, scope: .wholeName)])
        #expect(plan.canApply)
        _ = try await BatchRenamer.apply(plan)
        #expect(try names(in: dir) == ["PHOTO.JPG"])
    }

    @Test func folderAndLinkAreRenamedThemselves() async throws {
        let (dir, _) = try fixture([])
        defer { FaultFixture.remove(dir) }
        let folder = dir.appendingPathComponent("folder")
        try FaultFixture.write(to: folder.appendingPathComponent("inside"))
        let link = try FaultFixture.danglingLink(at: dir.appendingPathComponent("link"))
        let plan = try BatchRenamePlanner.plan(sources: [folder, link], names: ["folder 2", "link 2"])
        _ = try await BatchRenamer.apply(plan)
        #expect(try names(in: dir) == ["folder 2", "link 2"])
        #expect(try names(in: dir.appendingPathComponent("folder 2")) == ["inside"])
    }

    @Test func aBlockedPlanIsRefused() async throws {
        let (dir, urls) = try fixture(["a", "b"])
        defer { FaultFixture.remove(dir) }
        let plan = try BatchRenamePlanner.plan(sources: [urls[0]], names: ["b"])
        await #expect(throws: BatchRenameError.self) { try await BatchRenamer.apply(plan) }
        #expect(try names(in: dir) == ["a", "b"])
    }

    @Test func aFileAppearingAfterThePreviewStopsTheWholeBatch() async throws {
        let (dir, urls) = try fixture(["a", "b"])
        defer { FaultFixture.remove(dir) }
        let plan = try BatchRenamePlanner.plan(sources: urls, names: ["x", "y"])
        try FaultFixture.write(to: dir.appendingPathComponent("y"))
        await #expect(throws: BatchRenameError.self) { try await BatchRenamer.apply(plan) }
        #expect(try names(in: dir) == ["a", "b", "y"])
    }

    @Test func noPermissionLeavesEverythingAsItWas() async throws {
        let (dir, urls) = try fixture(["a", "b"])
        defer { FaultFixture.remove(dir) }
        let plan = try BatchRenamePlanner.plan(sources: urls, names: ["x", "y"])
        try await FaultFixture.withReadOnly(dir) {
            await #expect(throws: BatchRenameError.self) { try await BatchRenamer.apply(plan) }
        }
        #expect(try names(in: dir) == ["a", "b"])
    }

    @Test func aFailureHalfwayRollsBackWhatLanded() async throws {
        let (dir, _) = try fixture([])
        defer { FaultFixture.remove(dir) }
        let open = dir.appendingPathComponent("open/a"), locked = dir.appendingPathComponent("locked/b")
        try FaultFixture.write(to: open)
        try FaultFixture.write(to: locked)
        let plan = try BatchRenamePlanner.plan(sources: [open, locked], names: ["x", "y"])
        try await FaultFixture.withReadOnly(locked.deletingLastPathComponent()) {
            await #expect(throws: BatchRenameError.self) { try await BatchRenamer.apply(plan) }
        }
        #expect(try names(in: open.deletingLastPathComponent()) == ["a"])
        #expect(try names(in: locked.deletingLastPathComponent()) == ["b"])
    }

    @Test func aFailureMidSwapRestoresBothNames() async throws {
        let (dir, _) = try fixture([])
        defer { FaultFixture.remove(dir) }
        let a = dir.appendingPathComponent("open/a"), b = dir.appendingPathComponent("open/b")
        let locked = dir.appendingPathComponent("locked/c")
        for url in [a, b, locked] { try FaultFixture.write(Data(url.lastPathComponent.utf8), to: url) }
        let plan = try BatchRenamePlanner.plan(sources: [a, b, locked], names: ["b", "a", "d"])
        try await FaultFixture.withReadOnly(locked.deletingLastPathComponent()) {
            await #expect(throws: BatchRenameError.self) { try await BatchRenamer.apply(plan) }
        }
        #expect(try names(in: a.deletingLastPathComponent()) == ["a", "b"])
        #expect(try String(contentsOf: a, encoding: .utf8) == "a")
    }

    @Test func cancellingRollsBack() async throws {
        let (dir, urls) = try fixture(["a", "b", "c"])
        defer { FaultFixture.remove(dir) }
        let plan = try BatchRenamePlanner.plan(sources: urls, names: ["x", "y", "z"])
        let task = Task {
            try await BatchRenamer.apply(plan) { done, _ in
                if done == 2 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try names(in: dir) == ["a", "b", "c"])
    }

    @Test func progressReachesTheTotal() async throws {
        let (dir, urls) = try fixture(["a", "b"])
        defer { FaultFixture.remove(dir) }
        let plan = try BatchRenamePlanner.plan(sources: urls, names: ["b", "c"])
        let seen = Seen()
        _ = try await BatchRenamer.apply(plan) { done, total in seen.add(done, total) }
        #expect(seen.values == [[1, 2], [2, 2]])
    }

    @Test func undoIsRefusedWhenAnOldNameIsTaken() async throws {
        let (dir, urls) = try fixture(["a", "b"])
        defer { FaultFixture.remove(dir) }
        let journal = try await BatchRenamer.apply(BatchRenamePlanner.plan(sources: urls, names: ["x", "y"]))
        try FaultFixture.write(to: dir.appendingPathComponent("a"))
        await #expect(throws: BatchRenameError.self) { try await BatchRenamer.undo(journal) }
        #expect(try names(in: dir) == ["a", "x", "y"])
    }

    @Test func undoIsRefusedWhenAnItemHasGone() async throws {
        let (dir, urls) = try fixture(["a", "b"])
        defer { FaultFixture.remove(dir) }
        let journal = try await BatchRenamer.apply(BatchRenamePlanner.plan(sources: urls, names: ["x", "y"]))
        try FileManager.default.removeItem(at: dir.appendingPathComponent("y"))
        await #expect(throws: BatchRenameError.self) { try await BatchRenamer.undo(journal) }
        #expect(try names(in: dir) == ["x"])
    }

    @Test func anEjectedVolumeFailsWithoutFalseSuccess() async throws {
        let volume = try ScratchVolume()
        let urls = ["a", "b", "c"].map { volume.url.appendingPathComponent($0) }
        for url in urls { try FaultFixture.write(to: url) }
        let plan = try BatchRenamePlanner.plan(sources: urls, names: ["x", "y", "z"])
        await #expect(throws: BatchRenameError.self) {
            try await BatchRenamer.apply(plan) { done, _ in
                if done == 1 { try? volume.eject() }
            }
        }
    }
}

private final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [[Int]] = []
    func add(_ done: Int, _ total: Int) { lock.lock(); stored.append([done, total]); lock.unlock() }
    var values: [[Int]] { lock.lock(); defer { lock.unlock() }; return stored }
}

@Suite struct TextPlanTests {
    @Test func oneLinePerItem() throws {
        let (dir, urls) = try fixture(["a", "b"])
        defer { FaultFixture.remove(dir) }
        let plan = try BatchRenamePlanner.plan(sources: urls, text: "x\r\ny\n\n")
        #expect(plan.rows.map(\.newName) == ["x", "y"])
        #expect(plan.canApply)
    }

    @Test func aMissingOrExtraLineIsRefused() throws {
        let (dir, urls) = try fixture(["a", "b"])
        defer { FaultFixture.remove(dir) }
        #expect(throws: BatchRenameError.self) { try BatchRenamePlanner.plan(sources: urls, text: "x") }
        #expect(throws: BatchRenameError.self) { try BatchRenamePlanner.plan(sources: urls, text: "x\ny\nz") }
    }

    @Test func aBlankLineInTheMiddleIsAnEmptyName() throws {
        let (dir, urls) = try fixture(["a", "b"])
        defer { FaultFixture.remove(dir) }
        let plan = try BatchRenamePlanner.plan(sources: urls, text: "\ny")
        #expect(plan.rows[0].status == .blocked(.emptyName))
    }
}

@Suite struct TextProcessTests {
    private func process(_ process: TextProcess, _ name: String, scope: RenameScope = .stem) throws -> String {
        try newNames([name], [.text(process, scope: scope)])[0]
    }

    @Test func spaces() throws {
        #expect(try process(.trimSpaces, "  a b  .txt") == "a b.txt")
        #expect(try process(.collapseSpaces, "a   b  c.txt") == "a b c.txt")
        #expect(try process(.spacesToDashes, "a b c.txt") == "a-b-c.txt")
        #expect(try process(.spacesToUnderscores, "a b.txt") == "a_b.txt")
        #expect(try process(.separatorsToSpaces, "a_b-c.txt") == "a b c.txt")
    }

    @Test func characters() throws {
        #expect(try process(.removeAccents, "Crème brûlée.txt") == "Creme brulee.txt")
        #expect(try process(.fullWidthToHalfWidth, "ＡＢＣ１２３.txt") == "ABC123.txt")
    }

    @Test func scopeIsHonoured() throws {
        #expect(try process(.removeAccents, "é.é", scope: .fileExtension) == "é.e")
    }

    @Test func aProcessCanCreateACollision() throws {
        let (dir, urls) = try fixture(["a b.txt", "a  b.txt"])
        defer { FaultFixture.remove(dir) }
        let plan = try BatchRenamePlanner.plan(items: urls.map { RenameItem(url: $0) }, steps: [.text(.collapseSpaces, scope: .stem)])
        #expect(!plan.canApply)
    }

    @Test func survivesCoding() throws {
        let step = RenameStep.text(.removeAccents, scope: .wholeName)
        #expect(try JSONDecoder().decode(RenameStep.self, from: JSONEncoder().encode(step)) == step)
    }
}
