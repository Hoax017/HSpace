import Testing
import Foundation
import PathComplete

/// Pure logic Oracle: injected in-memory fixture, zero file system dependency
@Suite struct PathCompleteTests {
    static let fixture: @Sendable (String) -> [String] = { dir in
        switch dir {
        case "/": ["Users", "usr", "tmp"]
        case "/Users/": ["snake", "Shared"]
        case "/home/me/": ["Desktop", "dev", "Downloads"]
        default: []
        }
    }
    let completer = PathCompleter(homePath: "/home/me", listSubdirectories: Self.fixture)

    @Test func prefixFiltersCaseInsensitive() {
        #expect(completer.complete("/Users/s") == ["/Users/Shared/", "/Users/snake/"])
        #expect(completer.complete("/u") == ["/Users/", "/usr/"])
    }

    @Test func trailingSlashListsAll() {
        #expect(completer.complete("/Users/") == ["/Users/Shared/", "/Users/snake/"])
    }

    @Test func tildeExpandsToHome() {
        // Completion is case-insensitive ("D" also hits dev); sorted by localizedStandardCompare
        #expect(completer.complete("~/D") == ["/home/me/Desktop/", "/home/me/dev/", "/home/me/Downloads/"])
        #expect(completer.complete("~") == ["/home/me/Desktop/", "/home/me/dev/", "/home/me/Downloads/"])
    }

    @Test func relativeAndEmptyReturnNothing() {
        #expect(completer.complete("") == [])
        #expect(completer.complete("no-slash") == [])
    }
}
