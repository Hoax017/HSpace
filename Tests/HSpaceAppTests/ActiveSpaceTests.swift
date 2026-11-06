import AppKit
import Testing
@testable import HSpaceApp

@MainActor @Suite struct ActiveSpaceTests {
    private func window(_ style: NSWindow.StyleMask = [.titled]) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: style, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    @Test func aWindowElsewhereMovesOnceAndThenStaysPut() async {
        let window = window()
        defer { window.close() }
        window.collectionBehavior = [.managed]
        ActiveSpace.bring(window, isOnActiveSpace: false)
        #expect(window.collectionBehavior.contains(.moveToActiveSpace))
        await eventually("behaviour restored") { window.collectionBehavior == [.managed] }
    }

    @Test func aWindowAlreadyHereIsOnlyRaised() {
        let window = window()
        defer { window.close() }
        ActiveSpace.bring(window, isOnActiveSpace: true)
        #expect(!window.collectionBehavior.contains(.moveToActiveSpace))
        #expect(window.isVisible)
    }

    @Test func aFullScreenWindowIsNotMoved() {
        let window = window([.titled, .fullScreen])
        defer { window.close() }
        ActiveSpace.bring(window, isOnActiveSpace: false)
        #expect(!window.collectionBehavior.contains(.moveToActiveSpace))
    }
}

@MainActor @Suite struct DragShakeMonitorTests {
    private func shake(_ monitor: DragShakeMonitor) {
        for (i, x) in [0.0, 100, 0, 100, 0].enumerated() { monitor.dragged(x: x, time: Double(i) * 0.05) }
    }

    private func pasteboard() -> NSPasteboard {
        let board = NSPasteboard.withUniqueName()
        board.clearContents()
        return board
    }

    @Test func aShakeWithFilesSummons() {
        let board = pasteboard()
        let monitor = DragShakeMonitor(pasteboard: board)
        var summoned = 0
        monitor.onShake = { summoned += 1 }
        monitor.pressed()
        board.clearContents()
        board.writeObjects([URL(fileURLWithPath: "/tmp/a") as NSURL])
        shake(monitor)
        #expect(summoned == 1)
    }

    @Test func aShakeWithoutADragDoesNothing() {
        let board = pasteboard()
        board.writeObjects([URL(fileURLWithPath: "/tmp/a") as NSURL])
        let monitor = DragShakeMonitor(pasteboard: board)
        var summoned = 0
        monitor.onShake = { summoned += 1 }
        monitor.pressed()   // files left over from an earlier drag
        shake(monitor)
        #expect(summoned == 0)
    }

    @Test func aDragOfSomethingElseDoesNothing() {
        let board = pasteboard()
        let monitor = DragShakeMonitor(pasteboard: board)
        var summoned = 0
        monitor.onShake = { summoned += 1 }
        monitor.pressed()
        board.clearContents()
        board.setString("text", forType: .string)
        shake(monitor)
        #expect(summoned == 0)
    }

    @Test func itIsInstalledOnlyWhileOn() {
        _ = NSApplication.shared
        let monitor = DragShakeMonitor(pasteboard: pasteboard())
        #expect(!monitor.isEnabled)
        monitor.setEnabled(true)
        #expect(monitor.isEnabled)
        monitor.setEnabled(true)
        monitor.setEnabled(false)
        #expect(!monitor.isEnabled)
    }

    @Test func theMenuIsRegistered() {
        NSApplication.shared.mainMenu = MainMenu.build()
        #expect(MainMenu.uiTestMenuItem(for: #selector(AppDelegate.bringWindowsToActiveSpace(_:)))?.ownerTitle == L10n.t("menu.window"))
        #expect(KeyBindings.entry("bringToActiveSpace") != nil)
    }

    @Test func theDockMenuOffersIt() throws {
        let menu = try #require(AppDelegate().applicationDockMenu(NSApplication.shared))
        #expect(menu.items.first?.action == #selector(AppDelegate.bringWindowsToActiveSpace(_:)))
    }
}
