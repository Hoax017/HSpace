import Foundation
import HSpaceTestSupport
import Testing
@testable import HSpaceApp

/// H3: a drop on a Trash is refused while hovering, so the cursor never promises what the transfer would refuse.
@MainActor @Suite struct TrashDropTests {
    @Test func theTrashAndItsFoldersAreRefused() {
        let trash = TrashLocation.userTrash
        #expect(DropFeedback.refusesTrash(trash, in: nil))
        #expect(DropFeedback.refusesTrash(trash.appendingPathComponent("folder"), in: nil))
    }

    @Test func aLinkToTheTrashIsRefused() throws {
        let dir = try FaultFixture.tempDir("hspace-drop")
        defer { FaultFixture.remove(dir) }
        let link = dir.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: TrashLocation.userTrash)
        #expect(DropFeedback.refusesTrash(link, in: nil))
    }

    @Test func anOrdinaryFolderIsAccepted() throws {
        let dir = try FaultFixture.tempDir("hspace-drop")
        defer { FaultFixture.remove(dir) }
        #expect(!DropFeedback.refusesTrash(dir, in: nil))
    }
}

@Suite struct RepeatLimiterTests {
    @Test func repeatsInsideTheIntervalAreHeldBack() {
        var limiter = RepeatLimiter(interval: 3)
        let start = Date(timeIntervalSince1970: 0)
        let first = limiter.shouldShow(now: start)
        let tooSoon = limiter.shouldShow(now: start.addingTimeInterval(2.9))
        let later = limiter.shouldShow(now: start.addingTimeInterval(3))
        #expect(first)
        #expect(!tooSoon)
        #expect(later)
    }
}
