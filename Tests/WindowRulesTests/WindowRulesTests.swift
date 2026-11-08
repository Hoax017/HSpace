import Foundation
import Testing
import WindowRules

@Suite struct WindowOptionsTests {
    private let home = URL(fileURLWithPath: "/Users/me")
    private let docs = URL(fileURLWithPath: "/Users/me/Documents")

    @Test func theDefaultsKeepTodaysBehaviour() {
        let options = WindowOptions()
        #expect(options.launch == .restore)
        #expect(options.newWindow == .home)
        #expect(options.lastTab == .closeWindow)
        #expect(!options.quitAfterLastWindow)
    }

    @Test func unknownStoredWordsFallBackOneByOne() {
        let options = WindowOptions(launch: "home", newWindow: "somewhere", lastTab: nil, quitAfterLastWindow: true)
        #expect(options == WindowOptions(launch: .home, newWindow: .home, lastTab: .closeWindow, quitAfterLastWindow: true))
    }

    @Test func aNewWindowOpensAtHomeUnlessAskedOtherwise() {
        #expect(WindowOptions().newWindowFolder(home: home, current: docs, isFolder: { _ in true }) == home)
        let current = WindowOptions(newWindow: .current)
        #expect(current.newWindowFolder(home: home, current: docs, isFolder: { _ in true }) == docs)
    }

    @Test func aGoneOrMissingCurrentFolderGivesHome() {
        let current = WindowOptions(newWindow: .current)
        #expect(current.newWindowFolder(home: home, current: docs, isFolder: { _ in false }) == home)
        #expect(current.newWindowFolder(home: home, current: nil, isFolder: { _ in true }) == home)
        #expect(current.newWindowFolder(home: home, current: URL(string: "https://example.com")!, isFolder: { _ in true }) == home)
    }

    @Test func theSessionIsRestoredOnlyWhenWantedAndSaved() {
        #expect(WindowOptions().restoresSession(hasSavedWindows: true))
        #expect(!WindowOptions().restoresSession(hasSavedWindows: false))
        #expect(!WindowOptions(launch: .home).restoresSession(hasSavedWindows: true))
    }
}

@Suite struct AppExclusionsTests {
    @Test func idsAreCheckedSortedAndKeptOnce() {
        let list = AppExclusions(["com.b.app", "com.A.app", "com.a.APP", "not an id", "", ".com.x", "com..x", "com.x."])
        #expect(list.bundleIDs == ["com.A.app", "com.b.app"])
    }

    @Test func matchingIgnoresCase() {
        let list = AppExclusions(["com.apple.dt.Xcode"])
        #expect(list.excludes("com.apple.dt.xcode"))
        #expect(!list.excludes("com.apple.dt"))
        #expect(!list.excludes(nil))
    }

    @Test func addAndRemove() {
        var list = AppExclusions()
        let first = list.add("com.figma.Desktop")
        let again = list.add("COM.FIGMA.DESKTOP")
        let bad = list.add("bad id")
        #expect(first && !again && !bad)
        #expect(list.bundleIDs == ["com.figma.Desktop"])
        list.remove("com.figma.desktop")
        #expect(list.isEmpty)
    }

    @Test func hspaceItselfIsNeverSilenced() {
        let list = AppExclusions(["dev.hspace.app", "com.apple.dt.Xcode"])
        #expect(!list.silences(frontmost: "dev.hspace.app", own: "dev.hspace.app"))
        #expect(list.silences(frontmost: "com.apple.dt.Xcode", own: "dev.hspace.app"))
        #expect(!list.silences(frontmost: "com.apple.Safari", own: "dev.hspace.app"))
        #expect(!list.silences(frontmost: nil, own: "dev.hspace.app"))
    }
}
