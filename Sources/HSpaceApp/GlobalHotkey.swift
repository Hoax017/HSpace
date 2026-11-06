import AppKit
import Carbon.HIToolbox

/// Global show/hide hotkey (M24 user request: replaces the Raycast bridge).
/// Carbon RegisterEventHotKey, the system-sanctioned global hotkey channel; no Accessibility permission needed.
/// Semantics: HSpace in front -> hide; in background/covered -> activate and raise (open a new window if there is none).
/// The key combo is externalized in UserDefaults "globalHotkey" = "modsRaw|keyCode|displayString"; unset by default (recorded in Settings > General).
@MainActor
enum GlobalHotkey {
    private static var hotKeyRef: EventHotKeyRef?
    private static var handlerRef: EventHandlerRef?

    static let prefKey = "globalHotkey"

    /// Current binding (modsRaw is NSEvent.ModifierFlags.rawValue)
    static var current: (mods: NSEvent.ModifierFlags, keyCode: UInt32, display: String)? {
        guard let raw = UserDefaults.standard.string(forKey: prefKey) else { return nil }
        let parts = raw.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, let m = UInt(parts[0]), let k = UInt32(parts[1]) else { return nil }
        return (NSEvent.ModifierFlags(rawValue: m), k, String(parts[2]))
    }

    static func set(mods: NSEvent.ModifierFlags, keyCode: UInt32, display: String) {
        UserDefaults.standard.set("\(mods.rawValue)|\(keyCode)|\(display)", forKey: prefKey)
        apply()
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: prefKey)
        apply()
    }

    /// (Re)registers from the current preference; returns whether registration succeeded (unset = a clean unregister also returns true)
    @discardableResult
    static func apply() -> Bool {
        unregister()
        guard let (mods, keyCode, _) = current else { return true }
        var carbonMods: UInt32 = 0
        if mods.contains(.command) { carbonMods |= UInt32(cmdKey) }
        if mods.contains(.option) { carbonMods |= UInt32(optionKey) }
        if mods.contains(.control) { carbonMods |= UInt32(controlKey) }
        if mods.contains(.shift) { carbonMods |= UInt32(shiftKey) }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { _, _, _ in
            Task { @MainActor in GlobalHotkey.toggle() }
            return noErr
        }, 1, &eventType, nil, &handlerRef)
        let hotKeyID = EventHotKeyID(signature: OSType(0x4E53_5043) /* "NSPC" */, id: 1)
        let status = RegisterEventHotKey(keyCode, carbonMods, hotKeyID,
                                         GetEventDispatcherTarget(), 0, &hotKeyRef)
        return status == noErr
    }

    static func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef); Self.hotKeyRef = nil }
        if let handlerRef { RemoveEventHandler(handlerRef); Self.handlerRef = nil }
    }

    /// Show/hide toggle (hotkey callback; UISelfTest calls it directly for real-effect assertions)
    static func toggle() {
        let delegate = NSApp.delegate as? AppDelegate
        let bringsHere = Preferences.bringToActiveSpace
        if NSApp.isActive {
            // Active, but with its window on another Space: the owner sees nothing, so hiding would be the wrong way round
            if bringsHere, let window = delegate?.frontmostMainWindow, !window.isOnActiveSpace {
                ActiveSpace.bring(window)
            } else {
                NSApp.hide(nil)
            }
        } else {
            NSApp.unhide(nil)
            NSApp.activate()
            // unhide is asynchronous: isVisible from NSApp.windows is still false at this point, so asking it "is there a main window"
            // gets a false no, and each hotkey summon opens a surplus empty window (always on slow machines). Ask AppDelegate's window ledger instead:
            // it is updated synchronously in windowWillClose and is the only synchronously reliable answer.
            if delegate?.hasLiveMainWindow == true, let window = delegate?.frontmostMainWindow {
                if bringsHere { ActiveSpace.bring(window) } else { window.makeKeyAndOrderFront(nil) }
            } else {
                delegate?.openWindow(at: FileManager.default.homeDirectoryForCurrentUser)
            }
        }
    }
}
