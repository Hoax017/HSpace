import Foundation
@testable import HSpaceApp
import Testing

/// Reads the app sources, because the test build is a debug build and cannot see what a release build leaves out.
enum AppSources {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/HSpaceApp")

    static func all() throws -> [(name: String, text: String)] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
            .map { ($0.lastPathComponent, try String(contentsOf: $0, encoding: .utf8)) }
    }

    /// Code lines left once `#if DEBUG` regions are removed. Comments are dropped.
    static func releaseLines(of text: String) -> [String] {
        var debugOnly: [Bool] = []
        var kept: [String] = []
        for line in text.components(separatedBy: .newlines) {
            let code = line.trimmingCharacters(in: .whitespaces)
            if code.hasPrefix("#if") {
                debugOnly.append(code == "#if DEBUG")
            } else if code.hasPrefix("#else") {
                if !debugOnly.isEmpty { debugOnly[debugOnly.count - 1] = false }
            } else if code.hasPrefix("#endif") {
                _ = debugOnly.popLast()
            } else if !debugOnly.contains(true), !code.hasPrefix("//") {
                kept.append(code)
            }
        }
        return kept
    }
}

@Suite struct ReleaseGate {
    /// Selects defaults keys. These lines are outside track E's files, so they are listed here until they are changed.
    private func isKnownPendingHook(file: String, line: String) -> Bool {
        file == "MainWindowController.swift" && (line.contains("sidebarWidth.uitest") || line.contains("windowFrame.uitest"))
    }

    @Test func noEnvironmentTestHookReachesARelease() throws {
        var leaks: [String] = []
        for source in try AppSources.all() {
            for line in AppSources.releaseLines(of: source.text)
            where line.contains("HSPACE_") && !isKnownPendingHook(file: source.name, line: line) {
                leaks.append("\(source.name): \(line)")
            }
        }
        #expect(leaks == [])
    }

    @Test func theSelfTestIsNotInARelease() throws {
        let sources = try AppSources.all()
        for source in sources {
            let lines = AppSources.releaseLines(of: source.text)
            #expect(!lines.contains { $0.contains("UISelfTest.run(") }, "\(source.name)")
            #expect(!lines.contains { $0.contains("uiTestDeliverExternalOpen") }, "\(source.name)")
        }
        let selfTest = try #require(sources.first { $0.name == "UISelfTest.swift" })
        #expect(AppSources.releaseLines(of: selfTest.text).count < 10)
    }

    @Test func theScannerSeesThroughNestedConditions() {
        let text = """
        kept1
        #if DEBUG
        dropped1
        #if os(macOS)
        dropped2
        #endif
        #else
        kept2
        #endif
        // dropped comment
        """
        #expect(AppSources.releaseLines(of: text) == ["kept1", "kept2"])
    }
}
