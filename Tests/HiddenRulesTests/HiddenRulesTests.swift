import Foundation
import HiddenRules
import HSpaceContracts
import HSpaceTestSupport
import Testing

@Suite struct HiddenRuleSetTests {
    private func verdict(_ rules: [HiddenRule], _ path: String, folder: Bool = false) -> HiddenVerdict {
        HiddenRuleSet(rules).verdict(path: path, isFolder: folder)
    }

    @Test func namesMatchByPatternWithoutRegardToCase() {
        let rules = [HiddenRule(pattern: "*.LOG")]
        #expect(verdict(rules, "/a/build.log") == .hide)
        #expect(verdict(rules, "/a/build.txt") == .show)
    }

    @Test func questionMarksAndRanges() {
        #expect(verdict([HiddenRule(pattern: "file?.[ab]")], "/x/file1.a") == .hide)
        #expect(verdict([HiddenRule(pattern: "file?.[ab]")], "/x/file1.c") == .show)
    }

    @Test func aSlashMeansTheFullPath() {
        let rules = [HiddenRule(pattern: "/Users/*/node_modules")]
        #expect(verdict(rules, "/Users/me/node_modules") == .hide)
        #expect(verdict(rules, "/Volumes/x/node_modules") == .show)
    }

    @Test func excludeBeatsHideInAnyOrder() {
        let hide = HiddenRule(pattern: "*.log")
        let exclude = HiddenRule(pattern: "build*", effect: .exclude)
        #expect(verdict([hide, exclude], "/a/build.log") == .exclude)
        #expect(verdict([exclude, hide], "/a/build.log") == .exclude)
    }

    @Test func targetsKeepFilesAndFoldersApart() {
        let folders = [HiddenRule(pattern: "cache", target: .folders)]
        #expect(verdict(folders, "/a/cache", folder: true) == .hide)
        #expect(verdict(folders, "/a/cache") == .show)
        let files = [HiddenRule(pattern: "cache", target: .files)]
        #expect(verdict(files, "/a/cache") == .hide)
        #expect(verdict(files, "/a/cache", folder: true) == .show)
    }

    @Test func aScopeCoversItsFolderAndBelowOnly() {
        let rules = [HiddenRule(pattern: "*.tmp", scope: "/work")]
        #expect(verdict(rules, "/work/a.tmp") == .hide)
        #expect(verdict(rules, "/work/sub/a.tmp") == .hide)
        #expect(verdict(rules, "/working/a.tmp") == .show)
        #expect(verdict(rules, "/a.tmp") == .show)
    }

    @Test func disabledAndEmptyRulesDoNothing() {
        #expect(verdict([HiddenRule(pattern: "*", isEnabled: false)], "/a") == .show)
        #expect(HiddenRuleSet([HiddenRule(pattern: "")]).isEmpty)
    }

    @Test func aMalformedPatternMatchesNothingAndDoesNotCrash() {
        #expect(verdict([HiddenRule(pattern: "[")], "/a/b") == .show)
    }

    @Test func anExactRuleMatchesOnlyThatItemEvenWithPatternCharacters() {
        let url = URL(fileURLWithPath: "/a/report [v*2].txt")
        let rule = HiddenRule.exact(url, isDirectory: false)
        #expect(verdict([rule], url.path) == .hide)
        #expect(verdict([rule], "/a/report [v12].txt") == .show)
        #expect(verdict([rule], "/b/report [v*2].txt") == .show)
    }
}

@Suite struct HiddenRuleStoreTests {
    @Test func rulesSurviveARestart() throws {
        let dir = try FaultFixture.tempDir("hspace-hiddenrules")
        defer { FaultFixture.remove(dir) }
        let rules = [HiddenRule(pattern: "*.log", effect: .exclude, target: .files, scope: "/a")]
        try HiddenRuleStore(directory: dir).save(rules)
        #expect(HiddenRuleStore(directory: dir).rules() == rules)
    }

    @Test func aRuleWithoutAPatternIsRefused() throws {
        let dir = try FaultFixture.tempDir("hspace-hiddenrules")
        defer { FaultFixture.remove(dir) }
        let store = HiddenRuleStore(directory: dir)
        #expect(throws: HiddenRuleError.self) { try store.save([HiddenRule(pattern: "  ")]) }
        #expect(store.rules().isEmpty)
    }

    @Test func aFailedSaveKeepsTheOldRules() async throws {
        let dir = try FaultFixture.tempDir("hspace-hiddenrules")
        defer { FaultFixture.remove(dir) }
        let store = HiddenRuleStore(directory: dir)
        let kept = [HiddenRule(pattern: "a")]
        try store.save(kept)
        try await FaultFixture.withReadOnly(dir) {
            #expect(throws: HiddenRuleError.self) { try store.save([HiddenRule(pattern: "b")]) }
        }
        #expect(store.rules() == kept)
    }

    @Test func aDamagedFileIsKeptAndReported() throws {
        let dir = try FaultFixture.tempDir("hspace-hiddenrules")
        defer { FaultFixture.remove(dir) }
        try FaultFixture.write(Data("nope".utf8), to: dir.appendingPathComponent("hidden-rules.json"))
        let store = HiddenRuleStore(directory: dir)
        #expect(store.rules().isEmpty)
        #expect(store.takeProblem() != nil)
        #expect(store.takeProblem() == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).contains { $0.contains("corrupt") })
    }

    @Test func aDamagedFileThatCannotMoveBlocksWrites() async throws {
        let dir = try FaultFixture.tempDir("hspace-hiddenrules")
        defer { FaultFixture.remove(dir) }
        let file = dir.appendingPathComponent("hidden-rules.json")
        try FaultFixture.write(Data("nope".utf8), to: file)
        try await FaultFixture.withReadOnly(dir) {
            let store = HiddenRuleStore(directory: dir)
            #expect(throws: HiddenRuleError.self) { try store.save([HiddenRule(pattern: "a")]) }
        }
        #expect(try Data(contentsOf: file) == Data("nope".utf8))
    }
}
