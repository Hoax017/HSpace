import Testing
import Foundation
import DirectoryWatch

/// Black-box acceptance: only through the Contract public surface + real temp directories + real touches (no fakes or mocks).
/// `.serialized`: FSEvents is sensitive to system FS activity and parallel runs interfere, so this suite runs serially.
@Suite(.serialized) struct DirectoryWatchTests {

    private func makeTempDir() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hspace-dw-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func touch(_ dir: URL) throws {
        let f = dir.appendingPathComponent("f-\(UUID().uuidString).txt")
        try Data("x".utf8).write(to: f)
    }

    /// Polls until the count exceeds baseline, at most timeoutMS; returns true on a hit.
    private func waitForIncrease(_ counter: SignalCounter, over baseline: Int,
                                 timeoutMS: Int) async -> Bool {
        for _ in 0..<(timeoutMS / 50) {
            try? await Task.sleep(for: .milliseconds(50))
            if await counter.value > baseline { return true }
        }
        return false
    }

    @Test func receivesSignalAfterTouch() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let watcher = DirectoryWatch().watch(dir)
        defer { watcher.stop() }
        #expect(watcher.startupError == nil)

        let counter = SignalCounter()
        let consumer = Task { for await _ in watcher.signals { await counter.bump() } }
        defer { consumer.cancel() }

        try await Task.sleep(for: .milliseconds(200))   // let the FSEventStream finish scheduling
        try touch(dir)
        #expect(await waitForIncrease(counter, over: 0, timeoutMS: 1500))
    }

    /// North star regression: deep subtree changes must not signal (FSEvents' recursive reports must be blocked by the direct-child filter)
    @Test func deepSubtreeChangeDoesNotSignal() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let deep = dir.appendingPathComponent("a/b/c")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)

        let watcher = DirectoryWatch().watch(dir)
        defer { watcher.stop() }
        let counter = SignalCounter()
        let consumer = Task { for await _ in watcher.signals { await counter.bump() } }
        defer { consumer.cancel() }
        try await Task.sleep(for: .milliseconds(400))   // let stale events from stream setup drain
        let baseline = await counter.value

        try touch(deep)   // deep write: irrelevant to this directory's listing
        let increased = await waitForIncrease(counter, over: baseline, timeoutMS: 1200)
        #expect(!increased)

        try touch(dir)    // direct child write: must trigger
        #expect(await waitForIncrease(counter, over: baseline, timeoutMS: 1500))
    }

    @Test func stopSilencesFurtherChanges() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let watcher = DirectoryWatch().watch(dir)
        let counter = SignalCounter()
        let consumer = Task { for await _ in watcher.signals { await counter.bump() } }
        defer { consumer.cancel() }

        // First prove the watch is alive
        try await Task.sleep(for: .milliseconds(200))
        try touch(dir)
        #expect(await waitForIncrease(counter, over: 0, timeoutMS: 1500))

        // stop finishes the signal stream; give the consumer time to drain and exit its loop, then set the baseline
        watcher.stop()
        try await Task.sleep(for: .milliseconds(400))
        let baseline = await counter.value

        try touch(dir)
        try await Task.sleep(for: .milliseconds(1000))
        #expect(await counter.value == baseline)   // no new signals after stop
    }

    @Test func suspendThenResume() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let watcher = DirectoryWatch().watch(dir)
        defer { watcher.stop() }
        let counter = SignalCounter()
        let consumer = Task { for await _ in watcher.signals { await counter.bump() } }
        defer { consumer.cancel() }

        // First prove the watch is alive
        try await Task.sleep(for: .milliseconds(200))
        try touch(dir)
        #expect(await waitForIncrease(counter, over: 0, timeoutMS: 1500))

        // Suspend and drain in-flight events within the latency window, then set the baseline (background zero power)
        watcher.suspend()
        try await Task.sleep(for: .milliseconds(500))
        let baseline = await counter.value

        try touch(dir)
        try await Task.sleep(for: .milliseconds(800))
        #expect(await counter.value == baseline)   // changes during suspension produce no signals

        // After resume, new changes are observed again
        watcher.resume()
        try await Task.sleep(for: .milliseconds(200))
        try touch(dir)
        #expect(await waitForIncrease(counter, over: baseline, timeoutMS: 1500))
    }
}

/// Single-consumer signal counter (reads across phases under AsyncStream's single-consumer constraint).
private actor SignalCounter {
    private(set) var value = 0
    func bump() { value += 1 }
}
