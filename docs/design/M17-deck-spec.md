# M17 Custom Top Deck and Full-Height Sidebar: Design Spec

Condensed to the decisions that still apply. `DESIGN.md` records code reality and wins where the two differ; the mockup is `mockup-m17.html`.

<!-- Direction contract
THESIS: The native macOS pro-tool standard taken to its limit: Finder's material language × QSpace's density
       and topology. Character comes from structure and finish, not colour; the owner rejected all "flashy web colours".
OWN-WORLD: The existing theme system (Theme.accent, appearanceMode, accentColorHex), system materials
       (NSVisualEffectView .titlebar and .sidebar), SF Symbols, hairline dividers and the 4pt grid. With all content
       removed the topology is still recognisable: one divider running the full height, the stash pile at the top
       of the left column, the deck layers in the right column.
STORY: On opening, four things can be scanned at once: which pane has focus, where the path is, what is on the
       stash shelf, how far the tasks have run.
FIRST VIEWPORT: Left column = traffic light row + stash shelf (148) + bookmarks, iCloud, locations. Right column =
       workspace tab row + icon toolbar (36) + pane grid, each pane with its own address bar + status bar (24).
FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, and DESIGN.md.
-->

## Premises

- Hybrid rule: search panel, settings window, system dialogs, Quick Look and context menus stay native. Only the main window's top structure is custom.
- No new colours: only existing Theme and system semantic colours and materials.
- North star: four idle panes at 0.0% CPU. The deck is static controls, with no constant animation or timers.
- Gates: BG-1 (deck views do not call FileManager write APIs), FG-1 (no fake buttons), shortcuts go through the KeyBindings registry, configurable items go in Preferences.
- Grid: UI sizes follow the 4pt scale, enforced by `scripts/grid-lint.sh`. Only values up to 2 for hairlines and optical correction, and 0.5 fractions, are exempt.

## Window structure

NSToolbar is gone (`toolbar = nil`), which also removed I-10. The window uses `.fullSizeContentView`, hidden title, transparent titlebar, and system traffic lights in the left column's top row.

```
+---------------+------------------------------------------+
| traffic lights| [workspace 1][workspace 2]           [+] | tab row
|---------------|------------------------------------------|
| stash shelf   | icon toolbar (36)                        |
| (148)         |------------------------------------------|
|---------------|                                          |
| bookmarks     | pane grid (each pane has an address bar) |
| iCloud        |                                          |
| locations     |------------------------------------------|
|               | 287 items · 3 selected · 42.21 GB free   | status bar (24)
+---------------+------------------------------------------+
        one vertical divider, window top to bottom
```

- Left column: full-height `.sidebar` material with the traffic light row, stash shelf and bookmark outline.
- Right column: `TopDeckView` (`.titlebar` material) above `PaneGridController.view` and the status bar.
- Split: manual `NSSplitView`, min 160, max 320. When the sidebar is collapsed, the tab row leading inset is 80pt to clear the traffic lights.
- Dragging: blank deck and traffic light areas move the window. Double-clicking blank deck follows the system zoom preference.

The tab row was specified at 28 and became 40 with 28pt capsules (I-11, v0.9.1).

## Workspace tabs

- Native NSWindow tabbing was dropped (`tabbingMode = .disallowed`), since its bar spans the whole window and breaks the full-height divider.
- `WorkspaceManager` holds `[WorkspaceState]` and `activeIndex`, reusing the SessionStore encoding. Switching snapshots the grid back and restores the target through `grid.restoreSession`.
- Tabs are capsules with hover close and middle-click close; the active tab has a Theme.accent 0.18 fill. The title is the active pane's folder name.
- Shortcuts: ⌘W closes (the last tab closes the window), and ⌃⇥, ⌃⇧⇥, ⌘⇧] and ⌘⇧[ cycle. ⌘T duplicates the current workspace (v0.19.25).
- `workspaceTabLimit` defaults to 0 (no limit); above the limit the oldest is overwritten, as in QSpace.
- Sessions hold a workspaces array, and the old format migrates once. Dragging a tab out to its own window is deferred to v2.

## Icon toolbar (36pt)

Buttons are 24×24, SF Symbol point size 13, spacing 4, all icon plus tooltip.

Layout A1, left and right split, chosen by the owner:

`[sidebar] | [back forward up] | [view modes] -- flexible space, also the drag handle -- [AirDrop terminal tasks trash] | [layout modes]`

Clusters are 16pt apart with a hairline; frequent navigation and view controls sit left, global actions and layouts right.

Trash button (revised in v0.19.17): click always opens the Trash in-app, and dropping files moves them to the Trash. It is deliberately not "delete if there is a selection", because a selection almost always exists and someone heading to the Trash would delete files first. Existing delete entries stay (⌘⌫, context menu, Backspace setting), and Go menu > Trash (`goTrash`) is a second entry with no default shortcut.

## Official SF Symbols

Icons come only from `NSImage(systemSymbolName:)`, never custom paths, emoji or text.

| Action | Symbol |
|---|---|
| Back, forward, up | `chevron.backward`, `chevron.forward`, `arrow.up` |
| View modes | `square.grid.2x2`, `list.bullet`, `rectangle.split.3x1` |
| AirDrop | `airdrop` (fallback `dot.radiowaves.left.and.right`) |
| Open in terminal | `apple.terminal` (fallback `terminal`) |
| File tasks | `arrow.up.arrow.down` (avoids reading as refresh) |
| Layouts | `rectangle`, `rectangle.split.2x1`, `rectangle.split.1x2`, `rectangle.split.3x1`, `rectangle.split.2x2` |
| Sidebar toggle | `sidebar.leading` |
| Stash buttons | `doc.on.doc`, `arrow.forward.square`, `airdrop`, `trash`, `ellipsis.circle` |
| Sidebar rows | `folder.fill`, `icloud`, `internaldrive` with accent tint |

## Stash shelf: B2 hover-reveal

- At rest: only the pile and count pill (10% fill, tabular digits), centred in the 148pt area. The pile can grow to about 112×100.
- Hover for 150ms: an action bar floats up at the bottom (overlay material, hairline frame, shadow; five 20×20 buttons, spacing 4: copy, move, AirDrop, clear, more). It is an overlay and does not change layout (FG-4), and it hides on exit.
- Drag hover: the bar hides and an accent hairline inner ring shows the drop target.
- Empty: `tray.and.arrow.down` plus a muted hint. Clicking the count pill opens the per-item menu.

## Known traps

1. Restore the window frame after assigning `window.contentViewController` (assignment shrinks the window to `fittingSize`). `shouldCascadeWindows` is false and the app owns the `windowFrame` key.
2. `NSSplitViewController` leaks required W==320 and H==52 constraints, so keep the manual `NSSplitView`.
3. PaneGrid subviews need `autoresizingMask = [.width, .height]`; `makeSplit` assigns equal nominal frames.
4. Foundation's `resolvingSymlinksInPath` strips `/private` and breaks FSEvents, so use POSIX realpath.
5. `grep -cE` exits 1 on no match and breaks `&&` chains; BSD sed has no `\b`.
6. `QLPreviewPanel` needs `import QuickLookUI`.
7. `pod-lint-swift.sh` exempts `UISelfTest.swift` from BG-1, so self-test scenarios go in that file.

## Acceptance gates

Build, tests and pod-lint pass; `GRID_LINT_ALL=1 ./scripts/grid-lint.sh` exits 0; ui-smoke covers no NSToolbar, deck heights, ⌘T and ⌘W, the full-height divider, three collapse rounds without drift, and a centred stash group (within 2pt). Also required: screenshots of single, dual, quad and collapsed layouts in both appearances; four idle panes at 0.0% CPU over at least 6 samples; end-to-end persistence of frame, sidebar width and session; and every former toolbar action present and validated on the deck.
