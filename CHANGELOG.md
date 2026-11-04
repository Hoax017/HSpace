# Changelog

> Entries before the fork were condensed from the upstream changelog. Every version listed here is an upstream release; the original detail is in the git history. The self-updater that some entries describe was removed in the fork.

This project follows [Semantic Versioning](https://semver.org/). 0.y.z are development versions: each finished milestone bumps the minor version and gets a git tag.

## [0.19.27] - 2026-09-14

- Search splits queries on whitespace and every term must match (AND, any order, case- and diacritic-insensitive); both channels share `QueryTerms`. `override md` missed `OVERRIDE.md` because of the space, not because of case.
- Boundary guards: `NSMetadataQuery` crashes on a compound predicate with one subpredicate, so a single term is not wrapped in AND; a whitespace-only query ends at once, because an empty AND would match the whole disk.
- Ranking splits terms too, and a term found in its exact case adds 50 points. That is below the 200-point minimum gap between tiers, so case only reorders within a tier.
- I-74. Tests: 147 unit, 242 ui-smoke.

## [0.19.26] - 2026-09-13

- Removed per-pane tabs (M13 pane tabs retired). They were invisible by default while external opens kept piling into them, and `PRODUCT.md` only ever defined window-level workspace tabs. A pane is now one browsing context; the `activeTab` accessor name stays, and ⌥⌘T, ⌥⌘W, the pane tab bar menu item and `paneTabLimit` are gone.
- External opens land in a workspace tab via `openWorkspaceTab`. They never evict the oldest workspace (at the limit they navigate in place), and a multi-file reveal is grouped by parent folder.
- Storage: `SessionPane` went from `tabs + activeTabIndex` to `tab`. Old sessions migrate once, keeping only the active tab (not the first, and not expanded into workspaces); an out-of-range index does not fail the session decode.
- `restoreSession` skips panes whose target state equals their current state, so history, selection and scroll survive. I-71 is now a retirement proof that ⌥⌘T and ⌥⌘W are unbound; I-73 covers the three review regressions.

## [0.19.25] - 2026-09-13

- ⌘T now duplicates the current workspace: same layout, and each visible pane inherits path, sort, hidden-files and view mode (the previous fix had changed the ⌥⌘T path instead). Tests enter through the real menu item (I-70).
- Tabs became visible whenever a pane had several, and the pane tab commands fell back to the active pane when focus was outside any pane (I-71).
- Workspace tab bar: a click on the text did nothing because the hit landed on the `NSScrollView`. The bar now dispatches hits by x, removes the 6pt dead bands, and accepts first mouse (I-72).
- Empty Trash confirmation: Return really emptied the Trash when the app was inactive. Cancel is now the first button, which gets Escape, so Return is bound to nothing (I-63, I-64).

## [0.19.24] - 2026-09-13

- New tabs inherit sort, hidden-files and view mode from the current tab instead of the global default; the template is taken before the tab limit closes the oldest tab (I-69).

## [0.19.23] - 2026-09-11

- Sidebar highlight now follows the pane and clears when the current folder is not bookmarked, instead of showing a stale location.
- Clicking an already selected sidebar row now navigates: `outline.target/action` was added, with a flag to avoid double navigation (I-68). A self-test seam `handleClick(row:)` replaces synthetic `mouseDown`, which hung the self-test.

## [0.19.22] - 2026-09-08

- Conflict panel gains Keep Both, using the existing `keepBothName` naming (`file 2.txt`); it works for files and folders, while Merge stays folders only (M27).
- ⌘C and cut no longer clear the selection: `redraw()` now reloads by row and column instead of calling `reloadData()` (I-67).
- Group headers became a tinted title strip printed on the background, like QSpace. Collapsing was removed from list and icon views, since an arrow that does nothing is worse than none; group filtering stays.
- I-63 flake: the gate is now the real invariant (Cancel is the default and no file is lost); Return delivery is only required when the app is active.

## [0.19.21] - 2026-09-08

- ⌘V pastes clipboard content as a new file. Order is PNG, TIFF, PDF, RTF, plain text; a counter goes before the extension; an empty clipboard makes no file. `OperationSpec.contents` carries the data so the UI does not write to disk (BG-1, I-65).
- Row menus gain New File, and lists keep 40pt of right-clickable blank space through `contentInsets`, not fake rows. New File is bound to ⌥⌘N.
- Clicking the selected row renames after a double-click interval; double-click, keyboard, right-click or a selection change cancels it. Renaming is not offered in the Trash.
- Settings search: the index is read from the assembled view tree (215 items), so it cannot drift from the UI (I-66).

## [0.19.20] - 2026-09-08

- In the Trash root, the address bar shows an inline Empty button that hides on leaving the root or while editing the path. It uses a native confirmation defaulting to Cancel, and permanent deletion is reachable only from that result.
- `UISelfTest` was split from a 2300-line async function into named scenarios in the same order, cutting a controlled release build from 106 to 61 seconds (two samples on one machine, not clean-build figures).
- Added the `NSPACE_UITEST_ONLY=trash` focused entry. Tests on the real Trash only click Cancel; 132 unit tests and 220 ui-smoke assertions pass.

## [0.19.19] - 2026-09-07

- Empty Trash: `.delete` is handled by a new `Eraser` pod, not a LocalOps branch, because of its blast radius. `destination` is a required fence root: any source outside it rejects the whole batch, and the fence itself cannot be deleted. The entry is the trash button's context menu, defaulting to Cancel.
- Put Back: macOS put-back metadata is unreadable, so the new `TrashLedger` pod records original paths for items NSpace trashed and drops stale entries on read. The menu item only appears when a record exists.
- First-batch search throttling bypass is now tested deterministically through the `hasYielded` and `bufferedCount` probes.
- Not done: emptying several volumes at once; each volume is emptied separately. Tests: 150 unit, 212 ui-smoke (I-63); emptying only runs on temporary fixtures, never the real Trash.

## [0.19.18] - 2026-09-07

- Partial trash failures no longer lose what landed. `OperationReceipt` gains `failures` (additive contract change), `trashEntries` tolerates per-item errors and still throws if nothing succeeded, and the UI registers undo and reports "N moved, M failed".
- Breadcrumb hit margins no longer raise the collapse threshold: `chevronWidth` went from 16 to 8, so the per-level width is unchanged.
- Clicking an inactive pane's address bar now activates that pane. Dragging onto another window's trash button routes undo and the toast to the source window.
- Search: the result cap is enforced per item, before `seenPaths.insert`; the first batch skips the 300ms throttle. `sidebarWidth` gets a UITEST key like `windowFrame`.

## [0.19.17] - 2026-09-07

- Hidden-file search (`.claude`) had four causes, all fixed: DFS order (new `LevelOrderWalk`), emission only on batch size or completion (150ms time-based emission added), Spotlight filling the cap and starving the scan (`scanReserve` 500 and `spotlightReadBudget`), and skipped folders never matching themselves. First batch 17.9s to 0.151s. A per-directory `autoreleasepool` fixes BFS peak RSS (1219MB to 51.6MB).
- Trash: the deck button now always opens the Trash in-app and accepts dropped files, deliberately not "delete if there is a selection". Added Go menu > Trash (`goTrash`), a per-volume Trash, a toast for `moveToTrash`, an honest refusal for items already in the Trash, and disabled paste, new and duplicate inside it.
- Breadcrumb frames now fill the bar's height, so clicks no longer fall through into edit mode. Segments get a 4pt side margin via `segmentHitWidth`, and collapsing has a hard fit floor that cannot overflow.
- I-61, I-62. pod-lint gained four invariants and now strips comments before grepping. Tests: 133 unit, 202 ui-smoke.

## [0.19.16] - 2026-09-06

- Cold-start race: a Chrome reveal could open a second window, because `application(_:open:)` arrives before the async session restore. External opens now queue in `pendingExternalOpens` until `sessionReady` (I-60).
- `copyPaths` takes an injectable pasteboard, so I-59 uses a private `NSPasteboard` instead of the shared global one.

## [0.19.15] - 2026-09-04

- ⌘⇧C on empty space copies the current folder path in all three views: `copyPath` now falls back to the current directory and stays enabled (I-59).

## [0.19.14] - 2026-09-04

- The sort was saved, but the column header arrow was not restored because `sortDescriptors` was never set from the model. A model-to-header sync was added on first load, snapshot apply and optional-column rebuild (I-58).

## [0.19.13] - 2026-09-04

- Removed the dead `FinderIntegration.requestDefaultFolderHandler`: macOS locks `public.folder` to Finder, so `setDefaultApplication` always returns -50.

## [0.19.12] - 2026-09-02

- `BrowserState.navigate` compares `standardizedFileURL.path`, so spellings like `/a/b` and `/a/b/` no longer push duplicate history entries. Symlinks are deliberately not resolved, to keep stat off the navigation path (I-57).

## [0.19.11] - 2026-09-02

- The address bar now closes when the window resigns key, but only if its text is empty. Unconditional closing would turn "⌘L, copy elsewhere, ⌘V" into a file paste into the current folder (I-57).
- Assertions were strengthened: breadcrumb content, field editor release, and ⌘L through the real responder chain.

## [0.19.10] - 2026-09-02

- A pending reveal now moves to the new view when the view mode changes, via `takePendingReveal()` (I-56).
- The completion re-entrancy flag is set at scheduling time and reset with `defer`. Path errors are announced to VoiceOver.
- Not changed: `PathCompleter` stays directories-only, matching Finder ⌘⇧G and the pod's contract. There is no project-wide accessibility labelling yet.

## [0.19.9] - 2026-09-02

- Rebuilding the pane grid while editing the address bar left the keyboard dead; focus now moves to the active pane after `rebuildGrid()` (I-56).

## [0.19.8] - 2026-09-02

- The invalid-path shake now uses `layer.position.x`, not `frame.midX`; the bar was jumping 194pt (I-55).
- Pasting a file path works in column view: a stale column no longer consumes the desired selection.
- The external-open fallback picks the frontmost visible main window, and focus-loss reset now only applies when focus moves to another control in the window.
- I-47 and I-50 session assertions poll instead of using a fixed sleep.

## [0.19.7] - 2026-09-02

- Address bar and reveal edge cases (I-55): case-mismatched paths are normalized, a named hidden file turns hidden files on for that tab, and an unresolved `pendingReveal` is cancelled once the folder loads.
- Tab completes (a unique match, or the longest common prefix) instead of leaving the field; the address bar accepts dropped files.
- Path resolution moved off the main thread so dead network volumes cannot hang the app. Losing focus no longer steals focus back, and switching apps keeps an unsubmitted path.
- Completion candidates that cannot form a correct path are no longer offered. Tests: 174 ui-smoke.

## [0.19.6] - 2026-09-02

- ⌘L selects the whole path. Pasted paths now resolve through a candidate list, covering trailing newlines, `file://`, percent encoding, quotes and backslash escapes, and the literal form always comes first (I-53, I-54).
- Pasting no longer opens the completion popup, which had been swallowing Enter, and candidates are trimmed to the last segment.
- Pasting a file path selects the file, with packages treated as files. Empty-address cases all reset, ⌘R is handled at `MainWindowController`, and invalid paths show inline red text while staying in edit mode.
- `GlobalHotkey.toggle()` uses the window ledger, avoiding an extra empty window after the async `unhide` and revived closed windows. `refreshChrome()` gained an `isViewLoaded` guard.

## [0.19.5] - 2026-08-29

- External "show file location" reuses the current window with a new tab by default instead of opening a new window each time. Settings > Behaviour offers new tab or new window, and the old `activePane` value maps to new tab (I-52).

## [0.19.4] - 2026-08-28

- Auto update check throttle reduced from 20 hours to 1 hour, and only successful checks record the check time (I-51).

## [0.19.3] - 2026-08-28

- Changing the sort now saves the session (1s debounce), so it survives an unclean exit (I-50).
- Folders-first now applies only when sorting by name, matching Finder; the setting was renamed accordingly.

## [0.19.2] - 2026-08-28

- Date groups are ordered by recency and follow sort direction (I-49); "Today" could sink to the bottom when folders-first was on.
- Revealed selections show the blue highlight, because the view now becomes first responder (I-48).

## [0.19.1] - 2026-08-27

- Navigation now saves the session (1s debounce), so an unclean exit no longer returns to home (I-47).
- `sessionStore` and `frecencyStore` use an isolated directory under UITEST, so test fixtures never reach real user data.

## [0.19.0] - 2026-08-27

- M28 habit-learning search: results rank by match quality plus frecency, with short queries weighted toward habit and long ones toward match. A setting (on by default) turns it off.
- Tiers: exact name, prefix, word boundary, substring, path substring, then subsequence abbreviation.
- New `Frecency` pod: `FrecencyStore` (actor, 30-day half-life, evicts lowest scores) and `SearchRanking` (pure logic). Accesses are recorded app-wide through `FileOpsCoordinator.recordAccess`.

## [0.18.6] - 2026-08-27

- Clicking inside a multi-selection collapsed after a double-click interval (about 0.5s, an `NSTableView` behaviour). `mouseDown` now collapses right after `super` unless a drag started; drag and double-click are unchanged (I-43).

## [0.18.5] - 2026-08-27

- Dismissing Quick Look with Space now fades out instead of shrinking into the icon: `sourceFrame` returns `.zero` while dismissing, and opening still zooms from the icon (I-45).
- Quick Look animation duration is system-controlled and no private API is used. Escape and other paths keep the default animation.

## [0.18.4] - 2026-08-27

- Third-party "show file location" (Antigravity IDE) now selects the file: the `select` argument of `MainWindowController` was being dropped, and hard-coded list reveals now go through the view-mode-aware `pane.reveal` (I-44).
- ui-smoke was overwriting the real `windowFrame`; UITEST now uses the isolated `windowFrame.uitest` key (I-46).

## [0.18.3] - 2026-08-27

- M29 human-friendly time: date groups use relative buckets (Today, Yesterday, This Week, This Month, Earlier This Year, then past years).
- Date columns are relative and hide the year within the current year, matching Finder. `Formatters.relativeDate(_:now:)` replaces all 8 `Formatters.date` call sites.
- `FileGrouping` gains an injectable `nowProvider` clock for deterministic tests.

## [0.18.2] - 2026-08-27

- Global search hang and CPU spike (I-42): the engine has a hard cap, `SearchLimits.maxResults` = 2000, and the panel appends or merges linearly instead of rebuilding per batch. A truncation hint appears at the cap.

## [0.18.1] - 2026-08-27

- Window size reset after updates: native state restoration raced the app's own frame restore, so `isRestorable` is now false and the `windowFrame` key is the only authority (I-41).
- The final frame is saved on close and `UserDefaults.synchronize()` runs at terminate.

## [0.18.0] - 2026-08-27

- M26 v2: icon view groups by year and month like the list view, with a shared switch; `FileGrouping` is the single source of truth, and selection is kept by URL.
- Column view is deliberately not grouped: Finder and QSpace do not, and it is an anti-pattern in narrow columns.
- I-34 size column single-line assertion added; ui-smoke 126.

## [0.17.0] - 2026-08-27

- M27: copying within a folder now asks instead of silently making a copy (⌘D stays silent). The conflict sheet has Cancel, Merge and Replace plus "apply to all conflicts in this folder"; Merge is folders only.
- Data safety: when the destination is the source, Replace and Merge become keep-both. Self-source detection uses inode identity, batch naming tracks names already taken, and deleting the destination is deferred to transfer time.
- I-33: same-pane clicks no longer refresh pane state twice.

## [0.16.0] - 2026-08-27

- I-39: ⌘↑ selects the folder you came from; new ⌘↓ Down Folder enters the selection or falls back to the most recent direct child in history. The two keys no longer leak into row selection.
- I-40: search results have a permanent path column (panel 700 to 880). Local search sorts by nearness to the root, with sort-then-merge streaming and root prefixes matched both raw and resolved.
- I-38: streamed batches no longer clear the selection, which is restored by URL.
- URL matching across views now compares standardized paths, fixing trailing-slash mismatches.

## [0.15.1] - 2026-08-26

- I-29: ad-hoc signing changed the fingerprint every build, so local builds now use a fixed self-signed "NSpace Dev" certificate (`SIGN_IDENTITY` overrides it, CI falls back to ad-hoc) and Info.plist gains `CFBundleIconName`.

## [0.15.0] - 2026-08-26

- M26: list view groups by year and month for date sorts, with collapsing, "show only this group", and an external "use groups" switch (QSpace parity).
- I-37: the address bar truncates long names in the middle and folds middle levels into a menu, with every level still reachable, replacing horizontal scrolling.
- Self-test fixes for path edit mode and the headless completion popup; 105 ui-smoke assertions.

## [0.14.1] - 2026-08-26

- I-35 privacy incident: a screenshot and mockup demo data leaked real file listings in the public repository. History was cleaned with filter-repo and force-pushed, README screenshots now come from the `NSPACE_UITEST_DEMO` fixture, and a pre-push sanitize gate was added with a local-only term list.
- Release notes now carry the matching CHANGELOG section.
- Fixes: I-30 first "/" in path editing, I-31 search result context menu, I-32 selection rebuilt by URL after a delete, I-34 size column single line.

## [0.14.0] - 2026-08-26

- M25: public repository github.com/SammySnake-d/NSpace with README, LICENSE and architecture notes; tag-triggered Release CI uploads the zip and sha256.
- Updater fixes: real error messages, default feed, quarantine removal, and an auto-download-ready mode (on by default).
- I-34 size column no longer wraps.

## [0.13.0] - 2026-08-26

- M24 global show/hide hotkey via Carbon, with no Accessibility permission needed; recorded in Settings > General, replacing a Raycast bridge.
- The always-failing "Set as default" button was replaced by an honest status statement (FG-1).

## [0.12.0] - 2026-08-26

- I-28: a "take over show file location" setting uses the global `NSFileViewer` key (the same mechanism as QSpace), applies at once and is reversible.
- Three-state detection warns about a stale pointer such as an uninstalled QSpace, which had caused Typora's dead "open file location". Added the `debug.lastExternalOpen` breadcrumb.

## [0.11.4] - 2026-08-26

- I-27 audit: every folder open path navigates in-app with no reveal leak, locked by a sandboxed assertion.

## [0.11.3] - 2026-08-26

- I-26 follow-up: full sort matrix of six columns in both directions, tested through the UI and unit tests.

## [0.11.2] - 2026-08-26

- I-26: Date Created and Date Added columns are now sortable; `SortSpec.Key` gains `created` and `added`, and the default sort setting was extended.

## [0.11.1] - 2026-08-26

- I-25 experiment: macOS 27 locks the default folder handler (all five arms returned -50, and QSpace cannot take it over either); the settings text now says so.
- Added reverse entry points: the Finder Services item "Open with NSpace" and the `nspace://open?path=` URL scheme.

## [0.11.0] - 2026-08-26

- M23 full-feature test matrix: 120 features catalogued, assertions up from 34 to 72 verifying real effects, and 16 manual-only items listed honestly.
- The test sandbox hard rule is now mechanical: the `assertSandboxed` guard.
- I-24: column view collapsed in both directions; both constraints fixed and assertions raised to content level.

## [0.10.2] - 2026-08-26

- I-20b: sidebar icons use Finder's own CoreTypes `Sidebar*.icns` templates.
- I-23: workspace tab text centred with symmetric padding; the close button is a hover overlay.

## [0.10.1] - 2026-08-26

- I-22: the sidebar could not re-expand. `NSSplitView`'s private collapse was dropped and collapse state is fully self-managed, with an assertion that the sidebar is really visible.

## [0.10.0] - 2026-08-26

- M22 version badge and GitHub self-update (`UpdateEngine` pod). M15 toasts finished for move, copy, stash, eject, compress and extract.
- M21 finish: tabular digits, muted size units, status bar selection pill; M14 icon sweep complete, with the conflict panel keeping text under FG-1.
- M19: layout keys, F5/F6 and ⌥⌘W moved to the key registry.
- M18: 34 grid deviations cleared and the grid-lint baseline file deleted.

## [0.9.3] - 2026-08-26

- I-21: ⌘W closes floating windows first, then workspace tabs, and returns to the last active tab (MRU); the Dock reopens after the last window closes.
- I-15 real cause: dead LaunchServices registrations from concurrent worktree builds; `build-app.sh` now cleans them on every build.
- I-18: double-clicking a folder search result enters it in the current pane. I-20: the Applications sidebar icon uses the system folder icon.
- Full Disk Access guidance improved, and I-19 was verified as not a defect, with a regression assertion added.

## [0.9.2] - 2026-08-26

- M20: final app icon "N": graphite glass with a cyan-to-blue geometric N (two bars for dual panes, the slash as divider), generated by `scripts/generate-icon.swift`.

## [0.9.1] - 2026-08-26

- I-12: tab clicks were eaten by window dragging; `mouseDownCanMoveWindow` is false on the tab views.
- I-11: tab row 28 to 40, capsule 20 to 28, text centred. I-16: nav and layout segments merged into one capsule.
- I-14: default bookmark seeds were never injected; `restoreMissingSeeds` plus a Restore Defaults button. I-15: re-register with LaunchServices before requesting.
- I-13: ⌘1..9 jump to workspaces, and view modes moved to ⌥⌘1/2/3. I-17: workspace tab limit exposed in settings. UITEST skips real session restore.

## [0.9.0] - 2026-08-26

- M17 custom top deck replaces NSToolbar: workspace tab row plus icon toolbar, full-height sidebar, and one divider from window top to bottom.
- Self-managed workspace tabs replace native tabbing: `WorkspaceManager` holds full layout snapshots, `workspaceTabLimit` is external, and old sessions migrate losslessly once.
- Stash shelf B2 hover-reveal action bar; `scripts/grid-lint.sh` enforces the 4pt grid in pre-commit. Added `PRODUCT.md`, the M17 spec and the mockup.
- Fixes I-06 to I-10, plus final icons (tasks `arrow.up.arrow.down`, layout `rectangle.split`, official AirDrop).

## [0.8.0] - 2026-08-26

- Archives: compress (zip, tar.gz, optional weak ZipCrypto password) and extract with system-tool-based format support, QSpace-style wrapping, and a settings page.
- Settings pages: Behaviour (Enter, Backspace, drag defaults, tab limits, external open target), Permissions (read-only Full Disk Access probe and first-run guide), Appearance (theme, accent, list font size, pane highlight and dimming).
- Sidebar rework: favorites merged into bookmarks as default seeds, iCloud group, draggable group headers.
- 19 commands moved to a registry with recordable shortcuts (⌘F current folder, ⇧⌘F global); selectable list columns; stash and density polish.

## [0.7.0] - 2026-08-25

- View modes per pane: icons ⌘1, list ⌘2, Miller columns ⌘3. Spotlight search ⌘F and ⌥⌘F, streamed, with a hidden-files channel beyond QSpace.
- Quick Look on Space, QSpace-style stash shelf, and full session restore (1s debounce, flush on quit, fallback to home). Added the README.
- Fixes: selection is restored by URL on FSEvents refresh; idle CPU of 25%+ fixed by filtering events to the folder and direct children, using POSIX realpath.
- North star measured: four panes at rest, CPU 0.0% across 6 samples, 47MB.

## [0.6.0] - 2026-08-25

- Window-level workspace tabs (a tab is a whole split layout), with pane tabs optional and hidden by default.
- Full drag and drop with Finder semantics and spring-loading, plus the stash shelf (persistent, batch copy or move, AirDrop).
- FSEvents refresh with zero-cost suspension for hidden panes, on-demand folder sizes, thumbnails, status bar, and a settings window (⌘,).
- ⌘W closes the workspace tab and ⇧⌘W the window. New pods StashStore and SessionStore.

## [0.5.1] - 2026-08-25

- Density moved toward QSpace: plain table style, row 24 to 22, font 13 to 12, tighter columns, tab bar 22px, address bar 26px.

## [0.5.0] - 2026-08-25

- Sidebar with favorites, persistent bookmarks and volumes (free space, eject).
- Full file operations: context menu, inline rename with rollback, cut dimming, F5/F6, ⌘Z trash undo, progress window, conflict panel.
- New pods: DirectoryWatch, FolderSize, IconThumb (UI wiring in 0.6.0), LocalOps, VolumeInfo, BookmarkStore; new probe subcommands.
- Fixes: blank `.app` icons, "0 KB free" on read-only volumes, and the toolbar covering the tab and address bars.

## [0.4.0] - 2026-08-25

- Multi-pane layouts (single, two columns, two rows, three columns, quad) with ⌃⌘1..5 or the toolbar, preserving pane state.
- Per-pane tabs (⌘T, ⌘W, middle-click), and Tab or ⇧Tab cycling pane focus with an address bar highlight.
- Fixed collapsed rows and columns by presetting equal frames before adding views to `NSSplitView`.

## [0.3.0] - 2026-08-25

- Breadcrumb address bar with segment jumps and chevron submenus; ⌘L path editing with PathComplete.
- History per tab: back ⌘[, forward ⌘], up ⌘↑.
- Fixed a 4.4GB memory explosion: walking up with `deletingLastPathComponent` looped forever because macOS returns "/.." for "/".

## [0.2.0] - 2026-08-25

- Single-pane view-based list with sortable columns; double-click opens files with the system default and enters folders.
- ⌘⇧. hidden files, ⌘R refresh, and in-place empty and no-permission states; UTType icon and kind caches, relative dates.

## [0.1.0] - 2026-08-25

- Meta-architecture baseline: META_COMPLIANCE.json, spec.md, pod-lint-swift.sh, pre-commit enforcement.
- Xcode-free build with SwiftPM and `build-app.sh`; CLT swift-testing setup in `scripts/test.sh`.
- OperationKernel, plus the DirectoryReader and Transfer pods (conflict resolution, byte-level copyfile progress, APFS clone fast path, cooperative cancel).
- `nspace-probe` CLI with `list` and `copy`.
