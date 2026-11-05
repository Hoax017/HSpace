# HSpace Technical Specification (spec.md)

> A native macOS multi-pane file manager modeled on the core experience of QSpace Pro. macOS 26+ / Swift 6 / pure AppKit / SwiftPM + script packaging (no Xcode).

## 1. North Star

**On macOS 26 and later, provide a multi-pane file manager that can fully replace Finder/QSpace day to day, with idle CPU ≈ 0%.**

- Users leave QSpace because of stutter and high CPU, so this product's first acceptance item is performance: directories with tens of thousands of entries open instantly and smoothly, and four idle panes sample at CPU ≈ 0% in `top`.
- Core experience loop: multi-pane layouts (1/2H/2V/3/4) + window-level workspace tabs + breadcrumb address bar + left bookmark sidebar + stash shelf + Space for Quick Look + complete file operations (queue/progress/conflicts/undo) + double-click uses the system default app + Reveal takeover, the Finder service and `hspace://` as entry points (macOS 26+ keeps the default folder handler locked to Finder).
- Anti-goals (not in v1): batch rename, hashing, folder sync, network drives, workspace shortcuts, color rules. All of these can be added later through new pods with zero intrusion.

## User Stories & Acceptance Examples

> The outside-in source of truth for requirements (see references/spec-by-example-and-bdd-masters.md): user stories state "what is wanted", and the state machines, data contracts and fault-tolerance matrix below are their technical breakdown. The two directions must close. Each story comes with machine-checkable Given-When-Then key examples (positive/boundary/failure).

- **US-1 Move files side by side across panes**: As someone organizing files, I want to browse different directories side by side in two panes and move files from one side to the other, so I don't have to keep switching directories.
  - Positive: Given a two-column layout with 3 files selected in the left pane; When I press F6 (move to the other pane); Then the 3 files appear in the right pane's directory and disappear from the left pane, and the operation receipt has filesDone==3.
  - Failure: Given the target directory already has a file with the same name; When moving; Then the conflict panel appears (replace/merge/cancel + apply to this folder), and choosing cancel leaves source and target unchanged.

- **US-2 Same-directory copy never deletes by mistake**: As someone afraid of losing files, when I copy and paste within one folder, the source file must never be deleted, even if I slip and choose "Replace".
  - Boundary (self-source): Given the destination is determined by inode to be the source itself; When the decision is replace/merge; Then it always converges to keep-under-a-new-name (source intact, new copy added), and removeItem is never called on the source.

- **US-3 Find files by month**: As someone looking for recent files, I want list and icon views grouped by modification month so I can locate things quickly.
  - Positive: Given a directory with files from 3 different year-months, sort key = modification date, grouping on; When I open list or icon view; Then 3 headers with relative titles (today, yesterday, this week, this month, earlier this year, or the year) are shown, and right-clicking one offers "Show only this group". Headers do not collapse.

- **US-4 Settings and window size survive version updates**: As a long-term user, my window size, sidebar width, column visibility, bookmarks and shortcuts must stay exactly as they were after the app is updated to a new version, never reverting to defaults.
  - Positive: Given the window is sized to 1333×733 and the sidebar width and column visibility have been changed; When the .app is replaced with a new version and relaunched, or on any restart; Then the new version's window is still 1333×733 and all other settings are unchanged.
  - Root-cause invariant: window geometry is restored from a single authority, the self-managed `windowFrame` key, and `isRestorable=false` eliminates the race with native macOS restoration on version changes (when the system invalidates savedState). All settings live in `~/Library` (UserDefaults / Application Support), which an update does not overwrite.

- **US-5 Zero idle power**: As someone who keeps a file manager open all day, I don't want it burning CPU in the background.
  - Positive: Given four persistent panes and no activity; When `top` samples for 60s; Then process CPU ≈ 0% (FSEventStreams for background tabs/panes are really stopped, thumbnail requests are cancelled once scrolled away).

## 2. Responsibility Contract

| Object | Decision Owner | Execution Owner | Commit Owner | Lifecycle Owner | Proof Owner |
| --- | --- | --- | --- | --- | --- |
| File system changes (copy/move/trash/new/rename) | UI gathers intent → `FileOpsCoordinator` builds `OperationSpec` | Pod nodes such as `Transfer`/`LocalOps` | **The file system itself** (macOS); operation lifecycle state is committed solely by `OperationKernel.RunStore` | `OperationKernel` (queueing/cancellation/draining) | `OperationReceipt` returned by the node (bytes/target path/duration) + progress stream log |
| Directory display content | `DirectoryViewModel` (when to load/filter/sort) | `DirectoryReader` pod | No shared writable state: `DirectorySnapshot` is a read-only projection of the file system | Each pane's `PaneViewController` (suspend/resume) | Snapshot generation token + FSEvents callback timestamps |
| Bookmarks | `SidebarViewController` issues Commands | `BookmarkStore` pod | `BookmarkStore` actor (sole writer of `bookmarks.json`, atomic replace) | AppDelegate (load on launch/flush on quit) | JSON file on disk + version number |
| Stash shelf contents | `StashShelfViewController` issues Commands | `StashStore` pod | `StashStore` actor (sole writer of `stash.json`) | Same as above | JSON on disk + URL bookmark Data |
| Window/pane/tab session | `MainWindowController` (when to snapshot) | `SessionStore` pod | `SessionStore` actor (sole writer of `session.json`, 1s debounce) | AppDelegate | JSON on disk |
| Icon/thumbnail cache | Each view controller requests by visible row | `IconThumb` pod | No authoritative state (pure derived cache, discardable at any time) | `IconThumb` LRU | Cache hit rate is not required as evidence |

Single source of truth ruling: no UI component may call write-type FileManager APIs or write JSON directly. The presentation layer only issues Typed Commands and consumes read-only projections (BG-1/BG-5, machine-checked by pod-lint-swift.sh, which bans write-type APIs in the HSpaceApp directory).

## 3. State Machines

### 3.1 Operation Run state machine (committed solely by OperationKernel)

```
pending ──start──▶ scanning ──conflict found──▶ awaitingConflict ──user decision──▶ running
   │                  │ no conflict ──────────────────────────────────────────────▶ │
   │                  │                                                             ├──all done──▶ completed
   │                  │                                                             ├──node throws──▶ failed(errorClass)
   └──cancel──────────┴──cancel─────────────(any non-terminal state)────────────────┴──cancel────▶ cancelled
```

- Terminal states: `completed` / `failed` / `cancelled`, with no further transitions. Cancellation is cooperative (nodes check `Task.isCancelled` in the copyfile callback and return `COPYFILE_QUIT`).
- `awaitingConflict` suspends via `CheckedContinuation`; the conflict panel fills in the decision (replace/keep both/merge, optionally for the whole folder, or cancel) and execution resumes.

### 3.2 Directory browsing state machine (BrowserState per pane)

```
idle ──navigate(url)──▶ loading(gen=N) ──snapshot(gen=N)──▶ loaded ──FSEvent──▶ loading(gen=N+1)
                              │ snapshot(gen<N) arrives → discarded (generations prevent stale overwrites)
loaded ──pane/workspace switched away──▶ suspended (watcher/thumbnails suspended, mtime recorded) ──switched back──▶ loading if mtime changed, otherwise loaded
```

### 3.3 Inline rename (FG-6 optimistic rollback)

```
displaying ──Enter/menu──▶ editing(snapshot old name) ──commit──▶ renaming ──FS success──▶ displaying(new name)
                                │ Esc ──▶ displaying(old name)            └─FS failure──▶ atomic rollback to old name + in-place error banner
```

## Transition Matrix

Tabular truth for the operation Run state machine (3.1): (current state × event → next state); `—` marks an illegal transition (ignored). Terminal states have no further transitions.

| Current state \ Event | Scan start | Conflict found | No conflict | User decision | All done | Node throws | Cancel |
|---|---|---|---|---|---|---|---|
| pending | scanning | — | — | — | — | — | cancelled |
| scanning | — | awaitingConflict | running | — | — | failed | cancelled |
| awaitingConflict | — | — | — | running | — | failed | cancelled |
| running | — | — | — | — | completed | failed | cancelled |
| completed / failed / cancelled (terminal) | — | — | — | — | — | — | — |

- Directory browsing (3.2): `idle→loading(gen=N)→loaded`; an older snapshot (gen<N) is discarded on arrival; `loaded→suspended` (tab hidden) → back to `loading` or `loaded` depending on mtime.
- Inline rename (3.3): `displaying→editing→renaming→displaying`; on FS failure, atomic rollback to the old name.

## 4. Data Contracts

All are Sendable value types; a pod's public surface contains only contract types and protocols (Contract.swift).

```swift
// Directory projection (DirectoryReader output)
struct FileItem: Sendable, Hashable {
    let url: URL; let name: String
    let isDirectory: Bool; let isPackage: Bool; let isSymlink: Bool; let isHidden: Bool
    let size: Int64?              // file size in bytes; nil for directories (FolderSize backfills on demand)
    let modified: Date?; let created: Date?; let added: Date?
    let contentTypeID: String?    // UTType.identifier; the kind display string is derived and cached from this
}
struct DirectorySnapshot: Sendable {
    let directory: URL; let generation: UInt64
    let items: [FileItem]         // already sorted by SortOrder and filtered by showHidden
}

// Operation contract (UI → kernel)
struct OperationSpec: Sendable {
    enum Kind: String, Sendable { case copy, move, trash, duplicate, newFolder, newFile, rename, delete, compress, extract }
    let kind: Kind; let sources: [URL]; let destination: URL?
    let newName: String?          // for rename/newFolder/newFile
}
struct OperationProjection: Sendable {   // kernel → progress window (read-only projection, pushed via AsyncStream)
    let id: UUID; let kind: OperationSpec.Kind; let state: RunState
    let filesDone: Int; let filesTotal: Int
    let bytesDone: Int64; let bytesTotal: Int64
    let currentPath: String?              // a failure travels in RunState.failed(message:errorClass:)
}
enum ConflictDecision: Sendable { case replace, skip, keepBoth, mergeFolders, rename(String) }

// Three error classes (every pod Error must fall into one, BG-4/P6.4)
enum ErrorClass: Sendable { case logic /*internal logic error, never retry*/, transient /*system hiccup, retryable*/, external /*permissions/volume unavailable, tell the user*/ }
```

Storage contract: `~/Library/Application Support/HSpace/{bookmarks,stash,session,frecency,trash-ledger}.json`, Codable + atomic replace via temporary file; stash entries store URL bookmark `Data` (survives renames); session structure = window→workspace→frame/layout→pane→(path/view mode/sort/selection); frecency structure = path→(count/lastAccess).

## Preconditions

Guards that must hold before an operation is submitted (if not met, reject with in-place feedback, never leaving partial results or causing collateral damage):

| Operation | Precondition | If not met |
| --- | --- | --- |
| Copy/move (Transfer) | Source exists and is readable; target directory is writable; on a self-source conflict (destination==source, by inode) replace/merge safely converge to a rename | Reject and mark the progress row red; never delete the source on self-source |
| Move to Trash / rename (LocalOps) | Target is inside the mutable fixture, not a read-only volume; new name is non-empty and has no pending collision in the same directory | Atomic rollback to the old name + in-place error banner |
| Grouping (FileGrouping) | Preference enabled and sort key is date-based (modified/created/added) | No grouping, flat list |
| External open reuse (openFileURLs) | `externalOpenTarget != "newWindow"` and an active main window exists | Fall back to opening a new window |
| Session/frecency persistence | Only state changes after restore completes (sessionReady) are persisted | Changes during restore are blocked by the guard and never overwrite themselves |
| Mutating test operations (UISelfTest) | Target path is inside a self-created temporary fixture per assertSandboxed; session/frecency/windowFrame use UITEST-isolated keys/directories | Mechanically rejected; never touches the user's real files or preferences |

## 5. Fault-Tolerance Matrix

| Fault | Detection point | Handling | User-visible behavior |
| --- | --- | --- | --- |
| Directory unreadable (permissions/TCC not granted) | DirectoryReader throws external | `DirectoryViewModel` notifies its error handlers | In-place message in the pane, no dialog barrage |
| Source/target volume disappears mid-copy | copyfile returns error → external | Run→failed; fully copied files are kept, partial files are deleted | Progress row shows the failure in red |
| Name collision at copy target | ConflictScan pre-check | Run→awaitingConflict suspends | Conflict panel (Cancel / Merge / Keep Both / Replace) + apply to this folder |
| User cancels | Task.isCancelled → COPYFILE_QUIT | Run→cancelled; current partial file is cleaned up | Progress row shows "Cancelled" |
| FSEvents stream creation fails | DirectoryWatch returns transient | Degrade to manual refresh (⌘R works), no crash | Not noticed (auto-refresh silently stops) |
| JSON persistence fails (disk full) | Store atomic write throws | Keep in-memory state + retry on next debounce; in-place banner on repeated failure | One-time notice, does not block operations |
| Thumbnail generation crashes/times out | QLThumbnail error | Fall back to the generic UTType icon (BG-7: telemetry/decoration failures must not hurt the main chain) | Icon is just less fancy |
| Path gone during session restore | Per-tab stat at launch | That tab falls back to the home directory | Tab stays, location goes home |
| Rename FS failure | rename throws | FG-6 atomic rollback to the old name | In-place banner, white screens forbidden |

## 6. Craftsmanship Invariants

- **No real function, no UI element**: leave no dead buttons or placeholder menus; empty states, loading skeletons and disabled states are functions and must not be removed.
- **Close the loop in place**: every error and conflict is shown where it happens (banner/panel/inline red), with modal white screens and page jumps strictly forbidden.
- **Zero background power**: inactive workspaces/panes suspend watchers, cancel thumbnails, never poll. This is the north star, not an optimization item.
- **Finder muscle memory**: ⌥⌘1/2/3 views (⌘1..9 jump to workspaces), ⌘⇧. hidden files, ⌘⌫ Trash, Space for QL, ⌘L path, ⌘[/⌘] history, ⌘↑ up a level; light and dark follow the system automatically.
- **Localized UI**: all UI strings go through L10n, with English as the base.
- **4pt grid**: custom-drawn controls (breadcrumbs/tab bar/stash shelf) align spacing to a 4pt scale.
- **Observer-subject rule**: user-facing copy is always plain language ("Keep Both", not "the KeepBoth strategy").

## 7. Acceptance Checklist

- [ ] `swift test` all green (L-plan); `hspace-probe` drives DirectoryReader, Transfer, DirectoryWatch, FolderSize, IconThumb and ArchiveEngine alone (`list`, `copy`, `watch`, `size`, `thumb`, `compress`, `extract`; L-readonly / L-irreversible against a fixture tree in /tmp)
- [ ] `./scripts/run.sh` launches: browsing the home directory and /usr/bin with tens of thousands of entries opens instantly and scrolls smoothly
- [ ] Double-click a zip → Bandizip (system default app); double-click a folder navigates within the pane
- [ ] Four-way grid layout + window-level workspace tabs + Tab focus cycling + active pane highlight
- [ ] Breadcrumb click/chevron subdirectory jump/⌘L completion/drag file onto a segment
- [ ] Sidebar bookmarks drag-in, reorder, rename, delete; volume eject; iCloud Drive browsable
- [ ] Stash shelf drag-in → batch copy/move/AirDrop, persists across restarts
- [ ] Copy a multi-GB fixture tree: live byte progress, cancellable, conflict panel, ⌘Z undoes Trash
- [ ] Space Quick Look, arrow keys for continuous preview
- [ ] Terminal `touch` of a new file appears in the pane within 0.5s
- [ ] **Four idle panes sample at CPU ≈ 0% in `top`** (real sample output attached in the README)
- [ ] `hspace://open?path=` and a Reveal request open HSpace at the target with the item selected
- [ ] Restart restores the last panes/tabs/paths
