# M23: Full-Feature Test Matrix

Condensed from the original per-feature tables. Origin: on 2026-08-26 the owner found the sidebar could not re-expand, while the assertion had only checked size, not real visibility. Hence "every feature must be tested". The core principle: **assertions verify real effects, not the absence of a crash.**

## Testing constitution

**Rule 1: automated tests never touch real user files.**

1. All mutating file operations happen in a self-made sandbox, `hspace-uitest-<UUID>` under `FileManager.default.temporaryDirectory`. Fixtures are created by the test and always cleaned up, including on failure.
2. `UISelfTest.assertSandboxed(_:)` is the mechanical guard: a mutating target outside the sandbox fails the guard assertion and the operation is skipped.
3. Navigation, screenshot and selection scenarios may read real folders but never mutate them.

**Rule 2: real-effect assertions catch real bugs.** The M23 check that the column view is really in the hierarchy and visible caught I-24, where the view collapsed to 220×1. A required `stack.widthAnchor >= clip.widthAnchor` defeated the 999-priority fill constraints, and the fix lowered it to `.defaultLow`. Assertions that only checked window size could not see it.

## Sources of truth

The matrix is derived from `MainMenu.swift`, `KeyBindings.swift`, `TopDeckView.swift`, `FileContextMenuBuilder.swift` (all in `Sources/HSpaceApp/`), the settings pages, and the sidebar, stash shelf, search panel, progress window and info panel interactions.

## Numbers at M23

120 user-visible features, 34 existing assertions plus 37 new ones (4 of them sandbox guards), 71 PASS and 0 FAIL, 1 real bug found, 16 items left to manual testing. Current totals are in `CHANGELOG.md`.

## Coverage by area

| Area | Automated | Manual only |
|---|---|---|
| Menus | Settings, workspaces, new folder, Get Info, rename, duplicate, trash, copy path, view modes, layouts, sidebar toggle, hidden files, back, forward, up, home, search | About, Hide, Quit, ⌘N, Open, Quick Look, F5/F6, undo and redo, ⌘L text entry, minimize, zoom |
| Key registry | Default bindings read correctly | Recording, clearing and resetting; ⌃⇥ and Tab cycling, which need real key events |
| Top deck | Tab row, version badge, sidebar, navigation and its enabled state, view modes, layouts, tasks window, selection-driven enabling | Long-press history, AirDrop, terminal, window dragging |
| Context menus | Key items present, honest disabling, conditional items such as Add to Bookmarks and Extract | Open With candidates (real LaunchServices query) |
| Settings | The four `extraPages` (Archive, Behaviour, Permissions, Appearance): `makeView()` has no ambiguous layout and key controls exist | General, Shortcuts and Replace Finder are private builders that depend on singletons |
| Sidebar | Full height, collapse without drift, re-expand really visible, groups and seed rows | Bookmark rename and removal, group reorder, eject, restore defaults |
| Stash shelf | Add, remove, centring, overlay bar | AirDrop; copy and move share the transfer path covered elsewhere |
| Search panel | Opens, hidden-files switch visible | Live results, filters, Enter and double-click |
| Progress window | Empty state text, manual toggle | Rows, speed, cancel, failure text |
| Info panel | Appears, closes, path present | None |

Sort matrix (added for I-26): name, date modified, size, kind, date created and date added, each in both directions, through the column header path in the UI plus strict-weak-order unit tests.

## Honest exclusions (manual test steps)

1. **AirDrop**: select a file, click the deck AirDrop button, and confirm the share sheet lists nearby devices and can send.
2. **Full Disk Access prompt**: Settings > Permissions opens the system Full Disk Access page.
3. **Real mouse dragging**: drag to and from Finder, window drag, sidebar group reorder, drag into bookmarks, and spring-loading after about 0.8s; confirm targets and copy or move feedback match.
4. **Quick Look content**: Space shows a correct preview, and arrow keys page through items.
5. **External app opening**: double-click uses the default app, Open With lists candidates, and Open in Terminal starts iTerm or Terminal in that folder.
6. **System window and app actions**: minimize, zoom, new window, About, hide, quit.
7. **⌘L text entry**: type a path and press Return to navigate; Esc returns to the breadcrumb.
8. **Shortcut recording**: record a new combination, ⌫ clears, Esc cancels, the reset button restores the default.
9. **⌃⇥, ⌃⇧⇥ and Tab cycling**: confirm direction with several workspaces and panes.
10. **Search**: streamed results, scope, channel and kind filters, Enter reveals in the active pane, double-click enters folders.
11. **Progress rows**: copy a large file; the window appears after 0.5s with speed and progress, can cancel, and shows failures in red.
12. **Trash undo and redo**: ⌘Z restores to the original place, ⇧⌘Z redoes.
13. **Volume eject**: attach a USB drive or DMG and confirm the eject button unmounts it.
14. **Bookmarks**: rename, remove, and Settings > General restore defaults, which refills missing seeds and shows a count toast.
15. **F5 and F6**: copy or move to the other pane, with same-volume and cross-volume semantics.

The sixteenth original item, self-update download and install, no longer applies: the self-updater was removed in the fork.

## Where the assertions live

Scenario M23 in `Sources/HSpaceApp/UISelfTest.swift`, before search scenario 5 so the main window survives, with `require_pass` presence checks in `scripts/ui-smoke.sh`.
