import AppKit
import HSpaceContracts
import ViewStyles

/// App-wide view style store. A variable so that tests can give it a directory of their own.
@MainActor
enum ViewStylesHost {
    static var store: any ViewStyleStoring = ViewStyleStore(directory: AppDelegate.supportDirectory)
}

/// Per-folder view options. On the way into a folder with a rule, the pane's own options are set aside, and they come back on the way out.
/// While the rule is the folder's own, changing the view updates it, so "remember" means what it says.
extension PaneViewController {
    /// What the pane shows now
    var currentStyle: ViewStyle {
        let tab = activeTab
        return ViewStyle(viewMode: tab.viewMode.rawValue, sortKey: tab.model.sort.key.rawValue,
                         sortAscending: tab.model.sort.ascending, includeHidden: tab.model.includeHidden,
                         iconLayout: tab.viewMode == .icons ? tab.iconVC?.iconLayout ?? tab.folderIconLayout : tab.folderIconLayout)
    }

    /// What the pane would show without any rule
    static var defaultStyle: ViewStyle {
        ViewStyle(viewMode: Preferences.defaultViewModeRaw, sortKey: Preferences.defaultSortKey,
                  sortAscending: Preferences.defaultSortAscending, includeHidden: Preferences.showHiddenByDefault)
    }

    /// Sort and hidden files, before the folder is read, so it is read once. View mode follows through `finishFolderStyle`.
    func prepareFolderStyle(for directory: URL) -> PaneViewMode? {
        let tab = activeTab
        let target: ViewStyle
        if let rule = ViewStylesHost.store.rule(for: directory.path) {
            if tab.styleBaseline == nil { tab.styleBaseline = currentStyle }
            target = rule.rule.style
        } else if let baseline = tab.styleBaseline {
            tab.styleBaseline = nil
            target = baseline
        } else {
            return nil
        }
        applyOptions(of: target)
        return target.viewMode.flatMap(PaneViewMode.init(rawValue:))
    }

    func finishFolderStyle(_ mode: PaneViewMode?) {
        guard let mode, mode != activeTab.viewMode else { return }
        guard isViewLoaded else {
            activeTab.viewMode = mode
            return
        }
        let keyboardIsHere = (view.window?.firstResponder as? NSView)?.isDescendant(of: view) ?? false
        setViewMode(mode, takeFocus: keyboardIsHere)
    }

    private func applyOptions(of style: ViewStyle) {
        let model = activeTab.model
        var sort = model.sort
        if let key = style.sortKey.flatMap(SortSpec.Key.init(rawValue:)) { sort.key = key }
        if let ascending = style.sortAscending { sort.ascending = ascending }
        model.setViewOptions(sort: sort, includeHidden: style.includeHidden ?? model.includeHidden)
        activeTab.folderIconLayout = style.iconLayout
        activeTab.iconVC?.setFolderLayout(style.iconLayout)
    }

    /// Applies a style to this folder right away, and to the rule when the folder has one
    func applyStyle(_ style: ViewStyle) {
        applyOptions(of: style)
        activeTab.model.reload()
        if let mode = style.viewMode.flatMap(PaneViewMode.init(rawValue:)) { setViewMode(mode) }
        rememberViewChange()
    }

    /// The view changed: a folder with a rule of its own keeps the change
    func rememberViewChange() {
        let path = activeTab.browser.current.path
        guard let resolved = ViewStylesHost.store.rule(for: path), resolved.isExact,
              resolved.rule.style != currentStyle else { return }
        var rule = resolved.rule
        rule.style = currentStyle
        saveRule(rule, for: path)
    }

    private func saveRule(_ rule: FolderViewRule, for path: String) {
        do {
            try ViewStylesHost.store.setRule(rule, for: path)
        } catch {
            Toast.show(error.localizedDescription, in: view.window)
        }
    }

    var folderHasOwnRule: Bool { ViewStylesHost.store.rule(for: activeTab.browser.current.path)?.isExact == true }

    var folderRuleIncludesSubfolders: Bool {
        ViewStylesHost.store.rule(for: activeTab.browser.current.path).map { $0.isExact && $0.rule.includeSubfolders } ?? false
    }

    /// Remembers this folder's view, or forgets it. Forgetting leaves the view as it is until the pane moves on.
    func toggleFolderRule() {
        let path = activeTab.browser.current.path
        if folderHasOwnRule {
            do {
                try ViewStylesHost.store.removeRule(for: path)
            } catch {
                Toast.show(error.localizedDescription, in: view.window)
            }
        } else {
            if activeTab.styleBaseline == nil { activeTab.styleBaseline = currentStyle }
            activeTab.iconVC?.keepLayoutWithFolder()
            activeTab.folderIconLayout = activeTab.iconVC?.iconLayout
            saveRule(FolderViewRule(style: currentStyle), for: path)
        }
    }

    func toggleRuleIncludesSubfolders() {
        let path = activeTab.browser.current.path
        guard let resolved = ViewStylesHost.store.rule(for: path), resolved.isExact else { return }
        var rule = resolved.rule
        rule.includeSubfolders.toggle()
        saveRule(rule, for: path)
    }
}
