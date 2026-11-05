import BookmarkStore
import Foundation
import HSpaceTestSupport
import Testing
@testable import HSpaceApp

/// H2: the store answers 0 both for "nothing was missing" and for a failed write, and only one is a result to show.
@MainActor @Suite struct SeedRestoreTests {
    private func model(_ dir: URL) -> SidebarModel {
        SidebarModel(bookmarkStore: BookmarkStore(directory: dir))
    }

    @Test func aFailedWriteIsAFailureNotZeroRestored() async throws {
        let dir = try FaultFixture.tempDir("hspace-seeds")
        defer { FaultFixture.remove(dir) }
        let model = model(dir)
        chmod(dir.path, 0o555)
        let result = await model.restoreSeeds([(dir, "Seed")])
        chmod(dir.path, 0o755)
        guard case .failure = result else {
            Issue.record("expected a failure, got \(result)")
            return
        }
    }

    @Test func nothingMissingIsZeroWithoutAFailure() async throws {
        let dir = try FaultFixture.tempDir("hspace-seeds")
        defer { FaultFixture.remove(dir) }
        let model = model(dir)
        #expect(try await model.restoreSeeds([(dir, "Seed")]).get() == 1)
        #expect(try await model.restoreSeeds([(dir, "Seed")]).get() == 0)
    }
}
