import AppKit

/// Settings page plugin protocol: a new page = a new XxxSettingsPage.swift + one line in SettingsPages.extraPages
@MainActor
protocol SettingsPage {
    var pageTitleKey: String { get }
    func makeView() -> NSView
}

/// Parallel extension point: each feature area (archive/behavior/open mode/permissions/appearance) appends here
@MainActor
enum SettingsPages {
    static var extraPages: [any SettingsPage] = [
        ArchiveSettingsPage(),
        BehaviorSettingsPage(),      // Behavior + Open Mode
        PermissionsSettingsPage(),   // Permissions (Full Disk Access)
        AppearanceSettingsPage(),
    ]
}
