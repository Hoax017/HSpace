#!/usr/bin/env bash
# UI smoke: automated UX regression needing no system permissions (frame persistence end to end + view/layout size stability
# + empty task window + adding to stash + search panel). Output: /tmp/hspace-ui/{report.txt,*.png}
set -uo pipefail
cd "$(dirname "$0")/.."
./scripts/build-app.sh debug >/dev/null 2>&1 || { echo "Build failed"; exit 1; }
pkill -x HSpace 2>/dev/null; sleep 0.5
rm -rf /tmp/hspace-ui

BIN=build/HSpace.app/Contents/MacOS/HSpace
# Phase A: set frame 900x520 and exit (triggers autosave)
HSPACE_UITEST=1 HSPACE_UITEST_SETFRAME="900,520" "$BIN" >/dev/null 2>&1
# Phase B: relaunch, assert the restore + run all scenarios
HSPACE_UITEST=1 HSPACE_UITEST_EXPECTFRAME="900,520" "$BIN" >/dev/null 2>&1
CODE=$?
echo "==== UI smoke report (exit=$CODE) ===="
cat /tmp/hspace-ui/report.txt 2>/dev/null || echo "(no report)"
echo "Screenshots: $(ls /tmp/hspace-ui/*.png 2>/dev/null | wc -l | tr -d ' ') → /tmp/hspace-ui/"

# M17 assertion presence check (guards against an assertion deleted by mistake or an empty run going "green"): the report must contain these PASS lines
REPORT=/tmp/hspace-ui/report.txt
require_pass() {
  if ! grep -qF "PASS $1" "$REPORT" 2>/dev/null; then
    echo "✗ M17 assertion missing or failing: $1"; CODE=1
  fi
}
require_pass "No NSToolbar"
require_pass "Deck tab row height 40"
require_pass "Deck toolbar row height 36"
require_pass "Workspace tab bar exists in the deck"
require_pass "Version badge exists in the deck tab bar"
require_pass "Version badge has no update-state text"
require_pass "⌘T new workspace"
require_pass "⌘W close workspace"
require_pass "Sidebar column spans full height"
require_pass "3 collapse/expand rounds: window size and right column layout do not drift"
require_pass "Stash shelf contentGroup centered"
require_pass "Stash shelf action bar hidden at rest"

# I-19/I-21 regression assertions (v0.9.3)
require_pass "Global search panel has a visible 'Include Hidden Files' toggle"
require_pass "⌘W layering: closes the topmost settings window first"
require_pass "⌘W layering: main window workspace not closed by mistake"
require_pass "⌘W close falls back via MRU to the previously active workspace"
require_pass "Dock reopen gives a window after the last one was closed"
# I-22 regression (v0.10.1)
require_pass "Sidebar button really expands after collapsing"
# I-24b regression (v0.11.0)
require_pass "First column content really renders"
require_pass "Column header sort really works [name]"
require_pass "Column header sort really works [dateModified]"
require_pass "Column header sort really works [size]"
require_pass "Column header sort really works [kind]"
require_pass "Column header sort really works [created]"
require_pass "Column header sort really works [added]"
require_pass "Directory context Open = in-app navigation"
require_pass "Global hotkey registered"
require_pass "Global hotkey summon/hide toggle really works"

# M23 full-feature self-test matrix (v0.11.0): everything checks the "real effect", not "did not crash"
require_pass "View mode [list] matching view really in hierarchy and visible"
require_pass "View mode [icons] matching view really in hierarchy and visible"
require_pass "View mode [columns] matching view really in hierarchy and visible"
require_pass "Layout quad really shows 4 panes"
require_pass "Layout single really shows 1 pane"
require_pass "Navigation into sandbox takes effect"
require_pass "Navigation into subdirectory takes effect"
require_pass "Navigation back really returns to parent"
require_pass "Navigation forward really restores the path"
require_pass "Navigation up really goes to parent"
require_pass "Show-hidden-files toggle really flips model state"
require_pass "New folder really written to disk"
require_pass "Duplicate really written to disk"
require_pass "Rename really takes effect"
require_pass "Move to Trash really takes effect"
require_pass "Sandbox guard: new folder target inside own fixture"
require_pass "Sandbox guard: duplicate source inside own fixture"
require_pass "Sandbox guard: rename target inside own fixture"
require_pass "Sandbox guard: move-to-Trash target inside own fixture"
require_pass "Copy Path → clipboard content correct"
require_pass "Item context menu has all key items"
require_pass "Item context menu honestly disabled: non-archive selection has no 'Extract' item"
require_pass "Context 'Copy' enabled state follows selection correctly"
require_pass "Blank-area directory menu has 6 items including new folder/new file/paste/info/terminal"
require_pass "Task window manual open → visible"
require_pass "Task window manual close → hidden"
require_pass "Get Info panel appears"
require_pass "Get Info panel can be closed"
require_pass "Settings page [settings.tab.archive] makeView has no ambiguous constraints"
require_pass "Settings page [settings.tab.behavior] makeView has no ambiguous constraints"
require_pass "Settings page [settings.tab.permissions] makeView has no ambiguous constraints"
require_pass "Settings page [settings.tab.appearance] makeView has no ambiguous constraints"
require_pass "Shortcut registry default bindings read correctly"
require_pass "Sidebar has bookmarks group and seeded bookmark rows"
# I-31 search result row context menu (v0.13.x)
require_pass "Search result context menu items>0 and has 'Copy Path'"
require_pass "Search result context menu has reveal/add to stash/Get Info"
require_pass "Search result context 'Copy Path' → clipboard content == that path"

# I-30 regression: ⌘L path editing takes the first key at once + completion fires outside the text change transaction (first key popup not swallowed)
require_pass "I-30 ⌘L first key '/' lands at once"
require_pass "I-30 first key triggers completion candidates"
require_pass "I-30 completion fires outside the text change transaction"

# I-32 regression (selection clears after multi-select delete, all three views; checks the "real effect": view-layer selection really empty + no "selected" in the status bar)
require_pass "Selection clears after multi-select delete [list]"
require_pass "Selection clears after multi-select delete [icons]"
require_pass "Selection clears after multi-select delete [columns]"
require_pass "Sandbox guard [list]: I-32 move-to-Trash targets inside own fixture"
require_pass "Sandbox guard [icons]: I-32 move-to-Trash targets inside own fixture"
require_pass "Sandbox guard [columns]: I-32 move-to-Trash targets inside own fixture"

# I-37 regression: breadcrumb address bar fits its width (deep paths/long names do not overflow + middle collapse keeps all levels reachable; checks the "real effect")
require_pass "Sandbox guard: I-37 deep chain inside own fixture"
require_pass "I-37 breadcrumb does not overflow"
require_pass "I-37 '…' collapse segment exists and menu item count == collapsed levels"
require_pass "I-37 clicking a collapse menu item → pane really jumps to that level"
require_pass "I-37 visible last segment toolTip == full name"
require_pass "I-37 narrow pane still does not overflow"
# M26 list "year/month" grouping (checks real effects: headers/collapse/filter/selection across sorts/toggle)
require_pass "Sandbox guard [m26]: grouping fixture of 6 files inside own fixture"
require_pass "M26 group header count == 3, relative bucket titles correct, 2 items per group"
require_pass "M26 group header is a background bar, not collapsible"
require_pass "M26 show-only-this-group leaves that group + pill visible, show all restores"
require_pass "M26 selection stays by URL after cross-group re-sort"
require_pass "M26 grouping off: header count == 0, back to flat list"

# I-39 regression: ⌘↑/⌘↓ inverse navigation (going up auto-selects the originating child / going down is selection-driven first / no selection falls back to history / guard swallows the key)
require_pass "I-39 ⌘↑ auto-selects the originating child after going up"
require_pass "I-39 ⌘↓ enters the selected folder (selection-driven, not history fallback)"
require_pass "I-39 ⌘↓ with no selection falls back to the most recent direct child in history"
require_pass "I-39 ⌘↓ reaching the table view is swallowed without jump-select (guard really works)"

# I-38/I-40 regression: result stream does not disturb selection + local search ranks nearest-to-root first (same-level lexicographic/symlink convention/out-of-root sinks) + path column always shown
require_pass "I-40 local search ranks nearest-to-root first (direct children first)"
require_pass "I-40 result table always shows a rendered parent path column"
require_pass "I-40 same-level lexicographic order (a.txt before aa.txt, full order check)"
require_pass "I-40 resolved-path hits still sort by depth (symlink root does not break it)"
require_pass "I-40 out-of-root hit sinks to the last row"
require_pass "I-38 selection neither lost nor drifts when a new streamed batch arrives (row shift, still locked to the same URL)"

# M27 conflict experience (three buttons Cancel/Merge/Replace + per-folder batch via the "apply to this folder" checkbox + Merge disabled for file conflicts)
require_pass "M27 checkbox batch applies to one folder at a time"
require_pass "M27 per-folder batch: panel appearances == folder count (2 folders → 2 times)"
require_pass "M27 without the checkbox only the current item is settled (one by one)"
require_pass "M27 Cancel → resolution returns nil (abandon everything)"
require_pass "M27 panel has four buttons (Cancel/Merge/Keep Both/Replace) + bottom-left 'apply to this folder' checkbox (custom-drawn, really rendered)"
require_pass "M27 file conflict 'Keep Both' available"
require_pass "M27 file conflict 'Merge' disabled (folders only, honestly unclickable)"

# I-34 size column stays on one line + M26 v2 icon view grouping (section/collapse/filter/selection across rebuild)
require_pass "I-34 size column stays on one line (usesSingleLineMode + head truncation)"
require_pass "M26v2 icon view grouping section==3 relative bucket titles correct"
require_pass "M26v2 icon view group header is a background bar, not collapsible"
require_pass "M26v2 icon view show-only-this-group + pill, show all restores"
require_pass "M26v2 icon view selection stays by URL across rebuild"

# Window size persistence root cause (user report "size reverts to default after an update"): restore is self-managed, does not compete with macOS native restoration
require_pass "Window size self-restored: isRestorable=false (does not compete with macOS native restoration)"

# I-42 global search hang root cause: large streamed accumulation stays O(n) without stalling + truncation notice at the cap (engine-side cap: see SearchEngineTests)
require_pass "I-42 large streamed accumulation is O(n) without stalling"
require_pass "I-42 at the result cap shows the 'first N only' truncation notice"

# M29 humanized time: relative buckets (today/yesterday/this week/this month/earlier this year/prior years) + date column hides the year this year
require_pass "M29 relative buckets: 6 bucket keyTitle placement correct"
require_pass "M29 date column hides year this year, shows it otherwise"
# I-49 wrong group order (today pushed to the bottom): under foldersFirst groups still sort by relative recency
require_pass "I-49 foldersFirst groups still sort by recency: today (files only) is first, not pushed to the end by folder buckets"

# I-46 window size polluted by tests, root cause: UITEST frame key isolation (does not write the product windowFrame)
require_pass "I-46 UITEST frame key isolated (writes windowFrame.uitest, leaves the product windowFrame alone)"
require_pass "I-46 UITEST sidebar width key isolated"
# I-43 lag when collapsing a click inside the selection (waiting ~0.5s for AppKit's double-click interval): a plain click on a selected row in a multi-selection collapses early via a predicate
require_pass "I-43 click-inside-selection collapse predicate: plain click on a selected row in a multi-selection = collapse early; modifier/double click/outside selection/single selection = no intervention"
# M28 smart search ranking (frecency + match blend): on = high-frequency hits first / off = back to arrival order
require_pass "M28 smart sort on: high frecency hit ranks first"
require_pass "M28 smart sort off: back to arrival order"
# I-74 search case priority + queries with spaces (user report: searching "override md" did not find OVERRIDE.md)
require_pass "I-74 hits matching the query's case rank first"
require_pass "I-74 query with spaces works in result ranking too"
require_pass "M28/I-47 UITEST storage isolation (frecency/session written to a temp directory, real user data untouched)"
# I-47 restart returned to home: navigation persists immediately (an unclean exit loses nothing; before, location was saved only on clean exit)
require_pass "I-47 navigation persists immediately: session remembers the navigated directory"
# I-50 sort not persisted: sort changes persist immediately (an unclean exit loses nothing)
require_pass "I-50 sort change persists immediately: session remembers sort column/direction"
# I-52 configurable landing spot for external/browser reveal: default new tab in the existing window (no new window) / new window
require_pass "I-52 external open defaults to a 'new workspace tab': reuses the existing window, no new window"
require_pass "I-52 external open 'New Window': opens a new window"
# I-73 three new risks after external open moved to workspace tabs (caught in adversarial review)
require_pass "I-73 external open does not rebuild other panes: inactive pane selection kept"
require_pass "I-73 same-directory multi-file external open opens one workspace and selects the target file"
require_pass "I-73 at the workspace limit external open does not evict the oldest"
# I-44 third-party "open file location" really locates and selects (the select argument used to be dropped): wired up + list + icon view mode awareness
require_pass "I-44 openWindow(selecting:) really locates and selects the target file"
require_pass "I-44 list view reveal really locates and selects the target file"
require_pass "I-44 icon view reveal really locates and selects the target file (view-mode aware, not a hardcoded listVC)"
# I-48 no blue highlight on selection after reveal: the table takes focus after locating (selection shows accent blue)
require_pass "I-48 reveal focuses the table (selection shows blue accent, not unemphasized gray)"
# I-45 Quick Look dismiss fades (no longer shrinks to an icon point): dismiss state sourceFrame=.zero, open state = icon rect
require_pass "I-45 QL dismiss sourceFrame fades (.zero), open zooms from icon rect"

# I-53~I-57 three address bar bugs (⌘L select all / paste path + Enter navigates / restored after blur): user report
require_pass "Sandbox guard [I-53]: address bar regression fixture inside own temp directory"
require_pass "I-53 ⌘L selects all address bar text"
require_pass "I-53 Enter on folder path → navigates to that folder"
require_pass "I-53 edit field exits after folder navigation (breadcrumb shown again)"
require_pass "I-53 Enter on file path (.apk) → navigates to parent and selects the file"
require_pass "I-53 edit field exits after file reveal (breadcrumb shown again)"
require_pass "I-53 Enter on nonexistent path → no navigation (stays in place)"
require_pass "I-53 clearing address bar then blur → edit field exits, breadcrumb shows current path"
require_pass "I-53 going up while editing → edit field exits + breadcrumb shows new directory"
require_pass "Sandbox guard [I-54]: path resolution matrix fixture inside own temp directory"
require_pass "I-54 path resolution matrix 26/26 passed"
require_pass "I-54 ⌘L select-all then paste replaces everything (no append)"
require_pass "I-54 invalid path → no navigation + inline hint + stays in the field for in-place edits"
require_pass "I-54 emptied address bar then ⌘R refresh → menu action delivered via responder chain and edit field exits"
require_pass "I-54 pasting a file from the current directory → selected in place"
require_pass "I-54 paste does not pop up completion"
require_pass "I-54 completion candidates are the last segment, not the whole absolute path"
require_pass "Sandbox guard [I-55]: edge-case fixture inside own temp directory"
require_pass "I-55 path with case differing from disk still locates and selects"
require_pass "I-55 pasting a hidden file path → auto-shows hidden files and selects"
require_pass "I-55 target directory loaded but target still missing → pending reveal cancelled"
require_pass "I-55 Tab completes the sole candidate and stays in the field"
require_pass "I-55 multi-candidate Tab completes to longest common prefix"
require_pass "I-55 address bar registered the fileURL drag type"
require_pass "I-55 dragging a file onto the address bar → fills in its path"
require_pass "I-55 completion candidates with mismatched head all trimmed"
require_pass "I-55 shake is based on layer.position.x"
require_pass "I-55 pasting a file path in column mode also selects"
require_pass "I-56 layout switch while editing the address bar: focus stays on a control instead of falling back to the window"
require_pass "I-56 view mode switch during disk read moves the pending reveal target to the new view"
require_pass "I-57 window loses key: empty address bar collapses, any content is kept"
require_pass "I-57 after editing, breadcrumb really shows the current directory and field editor is released"
require_pass "I-57 ⌘L delivered via the real responder chain and selects all"
require_pass "I-57 different spellings of one directory do not stack in back history"
# I-58 sort indicator reverse sync (model → column header; this chain did not exist in product code before): user report
require_pass "I-58 model sort change syncs the column header indicator"
require_pass "I-58 indicator survives column rebuild"
# I-59 ⌘⇧C on blank area falls back to the current directory (three views): user report
require_pass "Sandbox guard [I-59]: copy-path fixture inside own temp directory"
require_pass "I-59 empty selection copy path falls back to the current directory"
# I-60 cold start external open queueing (Chrome "Show in Finder" opened a new window rather than a new tab): user report
require_pass "Sandbox guard [I-60]: external open queue fixture inside own temp directory"
require_pass "I-60 external open before session ready only queues, opens no window"
require_pass "I-60 after flush lands in a new workspace tab of the existing window"
# I-61 breadcrumb hit boxes (user report: you had to click the dead center of a folder to navigate; a little off and it went into typing mode)
require_pass "Sandbox guard [I-61]: hit box fixture inside own temp directory"
require_pass "I-61 segment hit box fills address bar height"
require_pass "I-61 chevron hit box fills address bar height"
require_pass "I-61 segment name keeps hit margin"
require_pass "I-61 full-height hit point triggers navigation (not edit mode)"
require_pass "I-61 right of the content edge is still blank and click enters editing"
require_pass "I-61 very narrow bar still does not overflow and all levels are reachable"
require_pass "I-61 total width per level matches the pre-change value"
require_pass "I-61 clicking an inactive pane's address bar → that pane activates"
# I-62 Trash (user report: no Trash feature, the trash button at top right did nothing/was always gray)
require_pass "Sandbox guard [I-62]: Trash fixture inside own temp directory"
require_pass "I-62 deck trash button usable with empty selection"
require_pass "I-62 clicking trash button → navigates to Trash in-app"
require_pass "I-62 Trash contents really listed"
require_pass "I-62 drag onto trash button → really moved to Trash"
require_pass "I-62 Go menu has a 'Trash' item wired to goTrash"
require_pass "I-62 controller lookup by window"
# I-63 Empty Trash (irreversible, Eraser pod) + Put Back (TrashLedger pod)
require_pass "Sandbox guard [I-63]: empty fixture inside own temp directory"
require_pass "I-63 trash button context menu has 'Empty Trash'"
require_pass "I-63 Empty Trash really deletes content and keeps the Trash itself"
require_pass "I-63 Return on the empty confirmation does not trigger emptying"
require_pass "I-63 Put Back round trip"
require_pass "I-63 items with no ledger record must not pretend they can be put back"
require_pass "I-63 item menu switches between Put Back and Move to Trash by location"
# I-64 'Empty' button at the right end of the address bar (user report: hidden in a context menu it might as well not exist)
require_pass "I-64 'Empty' button appears only in the Trash"
require_pass "I-64 really clicking 'Empty' opens the in-window confirmation, Return does not trigger emptying"
require_pass "I-64 cancelling Empty deletes nothing"
require_pass "I-64 'Empty' button hides while editing the address and returns after"
require_pass "I-64 Trash subfolder does not show 'Empty'"
# I-65 ⌘V pastes as a new file / click on selected item renames / blank bottom area / new-file shortcut (five user reports)
require_pass "Sandbox guard [I-65]: paste/rename fixture inside own temp directory"
require_pass "I-65 clipboard derivation: image before text, empty content makes no file"
require_pass "I-65 ⌘V pastes clipboard content as a new file"
require_pass "I-65 click-to-rename predicate: true only for 'single selection + click on selected row + no modifier + single click'"
require_pass "I-65 list bottom blank area right-clicks to the New menu"
require_pass "I-65 New File has a shortcut with no New Folder conflict"
# I-66 settings search box (user request: every setting searchable, jumping to its item)
require_pass "I-66 settings index built from the real view tree"
require_pass "I-66 results appear on input"
require_pass "I-66 clicking a result jumps to its tab"
require_pass "I-66 results area collapses after clearing search"
# I-67 copy/cut must not clear the selection (user report: the selection box vanished after ⌘C)
require_pass "Sandbox guard [I-67]: clipboard selection fixture inside own temp directory"
require_pass "I-67 selection survives copy/cut"
# I-68 sidebar navigates on one click + highlight follows the pane (user report: clicking "Downloads" did nothing until clicking something else and back)
require_pass "I-68 after a directory change the sidebar highlight no longer points at the old location"
require_pass "I-68 clicking the already highlighted sidebar row still navigates"
require_pass "I-68 sidebar highlight points to the bookmark directory while there"
# I-70/71/72 ⌘T new workspace inherits / ⌥⌘T tab bar visible / workspace tab bar clickable (user reports, entered from real menu key equivalents)
require_pass "Sandbox guard [I-70]: workspace fixture inside own temp directory"
require_pass "I-70 ⌘T new workspace copies the current workspace"
require_pass "I-72 workspace tab bar switches on text click and the full row is clickable"
require_pass "I-71 in-pane tabs retired"
require_pass "I-64 subfolder fixture put back"

echo "==== M17 assertion check complete (exit=$CODE) ===="
# Test sandbox hard rule wrap-up (I-46 / M28 / I-47): clear UITEST isolated state, never leave test residue in the user's real domain
defaults delete com.hoax017.hspace "windowFrame.uitest" 2>/dev/null || true
rm -rf "$TMPDIR/hspace-uitest-support" /tmp/hspace-uitest-support "$TMPDIR/hspace-uitest-frecency" /tmp/hspace-uitest-frecency 2>/dev/null || true
exit $CODE
