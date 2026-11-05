# HSpace roadmap

Goal: reach feature parity with QSpace Pro 7.0.4 as a reliable native macOS app, without copying any QSpace code, assets or license logic.

Last updated: 2026-11-04.

## How to use this file

- Tick a box in the same PR that finishes the item.
- Every item has an ID, a size and its dependencies. Refer to the ID in branch names and commits, for example `feat/L03-batch-rename`.
- Add new work here before starting it.

| Size | Meaning |
|---|---|
| S | One focused change in one module |
| M | One feature, several files |
| L | A new module or a cross-cutting change |
| XL | Needs a design note before coding |

### Definition of done

An item is done only when all of this is true. There is no lighter standard for personal use.

- Behaviour is covered by tests, including failure cases: no permission, disk full, volume ejected, cancelled.
- Errors reach the user. No `try?` on a path that can lose data.
- Long work shows progress, can be cancelled, and leaves no partial output.
- Destructive actions can be undone or ask first.
- Works with keyboard and VoiceOver, in light and dark mode, and in all view modes.
- Idle CPU stays at 0.0% with four panes open.
- `scripts/test.sh`, `pod-lint-swift.sh`, `grid-lint.sh` and `ui-smoke.sh` pass.

## What can run in parallel

```text
Phase 0  Safety baseline
  Tracks A to F run in parallel; G runs alongside them
        |
Gate 0: all P0 items closed, CI green  <-- required before any new feature
        |
Phase 1  Local parity
  Lanes 1 to 7 run in parallel, after their own first item
        |
Phase 2  Virtual file system  <-- sequential, blocks phases 3 and 4
        |
Phase 3  Protocols              Phase 4  Cloud
  Each protocol in parallel       Each provider in parallel
        |                              |
        +--------------+---------------+
                       |
Phase 5  Release quality
```

Rules for parallel work:

1. One lane, one git worktree, one branch.
2. A lane owns its files, listed under its heading. Two lanes must not edit the same file at once.
3. `Sources/HSpaceApp/MainMenu.swift`, `FileContextMenuBuilder.swift`, `SettingsWindowController.swift`, `KeyBindings.swift`, `Package.swift` and `Resources/en.lproj/Localizable.strings` are shared. Changes there are small, added last, and merged one at a time.
4. Changes to `Sources/HSpaceContracts` are never parallel: merge them first, then rebase the lanes.
5. New capability goes in a new pod under `Sources/Pods`, which is what makes lanes independent.

## Current state

Already in place, inherited from NSpace 0.19.27:

- [x] Multi-pane layouts, workspace tabs and session restore
- [x] List, icon and column views
- [x] Copy, move, rename, undo and conflict panel
- [x] Trash with Put Back, and permanent delete
- [x] Stash shelf with AirDrop
- [x] Search by name, content and kind, including hidden files
- [x] Sidebar bookmarks and volumes
- [x] Quick Look and Get Info
- [x] Compress to zip and tar.gz, extract tar, zip, gz, bz2 and xz
- [x] Configurable shortcuts, global hotkey and appearance settings
- [x] Reveal takeover, and "Open in HSpace" from Finder's Services menu

Done in the fork:

- [x] Self-updater removed
- [x] Repository in English, renamed to HSpace
- [x] Unit tests build with Command Line Tools

## Phase 0: Safety baseline

Come from the 2026-11-04 code audit, by reading the code. Each fix starts with a test that reproduces the problem. If it cannot be reproduced, record that and close the item.

### Track A: Transfer engine

Owns `Sources/Pods/Transfer`. Sequential within the track.

- [x] **A1** (L) Atomic replace: copy to a temporary name, then swap, so a failed copy keeps the old target. `InternalEngine.swift:75`
- [x] **A2** (M) Stop treating unreadable folders as empty, which can delete the source on a cross-volume move. `InternalEngine.swift:119`
- [x] **A3** (M) Delete the source of a cross-volume move only after verifying the copy. `InternalEngine.swift:97`
- [x] **A4** (M) Block a folder moved or copied into itself, and moves that replace a parent of the source. `InternalPlan.swift:166`
- [x] **A5** (M) Preserve symlinks as symlinks, handle cycles and dangling links. `InternalEngine.swift:109,206`
- [x] **A6** (S) Copy with `COPYFILE_EXCL` so a file that appears after the conflict check is not overwritten. Files were already safe (`COPYFILE_CLONE` implies EXCL); a folder appearing in that window was merged into, which is fixed.
- [x] **A7** (M) Remove partial output when a folder copy is cancelled.
- [x] **A8** (S) Make merge replace file over file only, as its contract says. `InternalEngine.swift:128`

### Track B: Archives

Owns `Sources/Pods/ArchiveEngine`.

- [x] **B1** (M) Extraction must not delete an existing item without asking. `InternalArchive.swift:177`
- [x] **B2** (S) Pass `--` before file names so a name starting with `-` is not read as an option; check zip `-TT` exposure. `InternalArchive.swift:59,63`
- [x] **B3** (S) Read process pipes while running to avoid a hang on large output. `InternalProcess.swift:35,71`
- [x] **B4** (M) Stop putting passwords on the command line, and stop accepting a password for tar.gz. `InternalArchive.swift:58,62,141`
- [x] **B5** (S) Handle selections from several folders. `InternalArchive.swift:24`

### Track C: Trash and recovery

Owns `FileOpsCoordinator.swift`, `Sources/Pods/Eraser`, `Sources/Pods/TrashLedger`.

- [x] **C1** (S) Use the move receipt in restore, so a failed move cannot rename an unrelated file. `FileOpsCoordinator.swift:408`
- [x] **C2** (S) Keep the Put Back record until restore succeeds. `FileOpsCoordinator.swift:198`
- [x] **C3** (S) Keep Put Back records for items that failed to delete. `FileOpsCoordinator.swift:175`
- [x] **C4** (M) Apply the "not into Trash" guard to drops, F5/F6 and the stash. `FileOpsCoordinator.swift:351`
- [x] **C5** (S) Keep ledger entries for unmounted volumes. `TrashLedger/Node.swift:80`
- [x] **C6** (S) Resolve symlinks in the Eraser fence check. `Eraser/Contract.swift:27`

### Track D: Saved data

Owns `Sources/Pods/BookmarkStore`, `StashStore`, `SessionStore`.

- [x] **D1** (M) A corrupt JSON file must be kept aside and reported, never overwritten. `TrashLedger/Node.swift:73`, `StashStore/Node.swift:74`, `BookmarkStore/Node.swift:128`
- [x] **D2** (S) Report failed bookmark writes instead of showing success. `MainWindowController.swift:316`
- [x] **D3** (S) Add a way to clear the local history of opened paths. `Sources/Pods/Frecency`

### Track E: App entry points

Owns `AppDelegate.swift`, `FinderIntegration.swift`, `UISelfTest.swift`.

- [x] **E1** (M) Harden `hspace://`: separate open from reveal, reject network and automount paths, do no blocking work on the main thread. `AppDelegate.swift:183`
- [x] **E2** (M) Compile `UISelfTest` and all environment test hooks out of release builds. `AppDelegate.swift:34`, `UISelfTest.swift:11` Open: `MainWindowController.swift:227,231` still read `HSPACE_UITEST` in release, and `ui-smoke.sh:6` must build with `build-app.sh debug`.
- [x] **E3** (M) Isolate test runs from real preferences, bookmarks, stash and clipboard. `MainWindowController.swift:46`, `AppDelegate.swift:140`
- [x] **E4** (S) Provide a way to restore the system Reveal setting. `FinderIntegration.swift:69` Open: `FinderIntegration.restoreSystemReveal()` exists; the Settings button still has to be added.
- [x] **E5** (S) Stop storing the last opened path in defaults. `AppDelegate.swift:206`

### Track F: Interaction safety

Owns `ConflictSheet.swift` and the drop handlers in the three view controllers.

- [x] **F1** (S) Replace must not be the Return default. `ConflictSheet.swift:216`
- [x] **F2** (S) Drop feedback must match the action taken. `FileIconGridViewController.swift:838`, `FileColumnViewController.swift:351`
- [x] **F3** (S) Honour the terminal setting in all view modes. `FileIconGridViewController.swift:663`

### Track G: Engineering

Owns `.github`, `scripts`, docs.

- [x] **G1** (M) Run build, tests and lints on every pull request. Proven on `macos-26` with Xcode 26.6, including the `hdiutil` volume tests.
- [x] **G2** (S) Pin workflow actions to commit hashes, and restrict token permissions. `release.yml:15,36`
- [x] **G3** (S) Install the pre-commit checks the docs promise, or remove the claims. `scripts/install-hooks.sh` installs them; run it once per clone. meta-doctor claims removed: it is not in this repository.
- [x] **G4** (S) `ui-smoke.sh` must not kill a running HSpace. `ui-smoke.sh:7`
- [x] **G5** (S) Fix `build-app.sh` path handling and `run.sh` install order. `build-app.sh:48`, `run.sh:8`
- [x] **G6** (S) Correct the docs where they disagree with the code: `spec.md`, `PRODUCT.md`, `DESIGN.md`, `README.md`.
- [x] **G7** (S) Add a failure-injection test helper shared by tracks A to D. Do this first.

### Track H: Phase 0 follow-ups

Found while closing tracks A to F. H1 to H3 touch shared files, so they run one at a time.

- [x] **H1** (M) Show `takeProblem()` from the stores in the UI, and give TrashLedger the D1 treatment. Closes D1
- [x] **H2** (S) Settings: clear history (D3), restore Finder for Reveal (E4), and no "0 restored" toast after a failed seed restore. Closes D3 and E4
- [x] **H3** (S) Refuse Trash drops in `validateDrop` through `FileOpsCoordinator.isTrashDestination`, with a message instead of a beep
- [x] **H4** (S) Update text after password removal (B4): `Contracts.swift:109`, `settings.archiveCryptoNote`, `README.md`
- [x] **H5** (M) Add an `HSpaceAppTests` target and drop the symlinks in `Tests/HSpaceKernelTests/AppEntryPoints`
- [x] **H6** (S) Restore: use landed URLs from receipts, skip redo after a failed restore, keep records for trashed dangling links
- [x] **H7** (M) Keep folder dates, tags and modes on cross-volume moves, and clean leftover `.hspace-transfer-*` items after a crash
- [ ] **H8** (S) Check a drop with the "move" preference and Option held. AppKit may refuse it
- [ ] **H9** (M) Run `ui-smoke.sh` on the merged code, then check by hand: Return in the conflict panel, drops, terminal, Put Back, `hspace://`
  - 2026-11-05 run on main: 237 passed, 5 failed. All 5 read `~/.Trash` (I-62, I-63, I-64) and report it unreadable. Likely cause: the test build has no Full Disk Access. Rerun after granting it to the debug build

**Gate 0:** tracks A to F and H closed, and G1 in place. No Phase 1 work merges before this.

## Phase 1: Local parity

Lanes run in parallel. Depends on Gate 0.

### Lane 1: File metadata

New pod `FileMetadata`.

- [ ] **L01** (M) Finder tags: read, set, filter, sort and a tag picker
- [ ] **L02** (S) Finder comments
- [ ] **L03** (M) File colours and rules
- [ ] **L04** (M) Custom folder icons and emoji, folder styles
- [ ] **L05** (M) Kind groups with a manager
- [ ] **L06** (S) Set default app per file kind

### Lane 2: Batch tools

New pods `BatchRename`, `FileHash`, `ImageConvert`.

- [x] **L10** (L) Batch rename: processors, sequence, date, case, replace, preview and collision check
- [x] **L11** (M) Batch rename presets and logs, with undo
- [x] **L12** (S) Quick rename variant for a few files
- [x] **L13** (M) File hash: MD5, SHA-1, SHA-256, compare, cancel
- [x] **L14** (M) Image conversion and resize. Vision-based actions stay a later option
- [ ] **L15** (M) Match and select by pattern
- [ ] **L16** (S) Text processing of selected names
- [ ] **L17** (S) Merge and flatten folders, depends on A8

### Lane 3: Viewing

Owns the view controllers and `Sources/Pods/IconThumb`.

- [ ] **L20** (L) Side preview panel, with configurable actions
- [ ] **L21** (L) File inspector panel
- [ ] **L22** (M) View options per folder, and saved view styles with a manager
- [ ] **L23** (M) Custom hidden items and exclusion rules
- [ ] **L24** (M) Folder sizes in list view, with a setting
- [ ] **L25** (M) Icon view options: size, spacing, label position
- [ ] **L26** (S) Keyboard selection with Space
- [ ] **L27** (M) Photos library browsing

### Lane 4: Navigation

Owns `BreadcrumbBar.swift`, `PathEditorField.swift`, `SidebarViewController.swift`, `TabBarView.swift`.

- [ ] **L30** (M) Recent tab switcher
- [ ] **L31** (M) Quick locations and go-to-bookmark panel
- [ ] **L32** (M) Quick launcher with commands
- [ ] **L33** (M) Sidebar item accent colours and palettes
- [ ] **L34** (M) Tab drag-out and reorder
- [ ] **L35** (S) Bring to active Space, drag-shake gesture

### Lane 5: Operations

Owns a new `Scheduler` pod and `ProgressWindowController.swift`. Depends on track A. L41 and L42 depend on L40.

- [ ] **L40** (L) Scheduler: queue, priorities, per-path locks, pause and resume
- [ ] **L41** (M) Task list window and toolbar status
- [ ] **L42** (M) Operation history with undo groups
- [ ] **L43** (L) Local folder sync: compare, filters, presets, direction, dry run. Must show a plan before any delete
- [ ] **L44** (M) New file templates, with `$date(format)` names

### Lane 6: Archives

Owns `Sources/Pods/ArchiveEngine`. Depends on track B.

- [ ] **L50** (L) Browse inside archives without extracting
- [ ] **L51** (M) Quick Look inside archives
- [ ] **L52** (L) 7z and RAR extraction, after a license and dependency review
- [ ] **L53** (M) Compression settings and password list stored in Keychain

### Lane 7: System integration

Owns new app extension targets. L60 and L61 need a proper Xcode target or an equivalent build step.

- [ ] **L60** (L) Finder Sync extension with badges
- [ ] **L61** (M) Share extension for the stash
- [ ] **L62** (L) AppleScript support: windows, panes, selection, stash
- [ ] **L63** (S) More Services: hash, batch rename, add to stash
- [ ] **L64** (M) Context menu customization
- [ ] **L65** (M) Preferences export and import
- [ ] **L66** (M) Workspace and window management options, app exclusions
- [ ] **L67** (M) Desktop mode, if it is still useful on macOS 26
- [ ] **L68** (M) French localization

**Gate 1:** all local items closed or explicitly dropped below.

## Phase 2: Virtual file system

Sequential. Nothing in phases 3 and 4 starts before this is merged. Depends on L40 and track A.

- [ ] **V1** (XL) Design note: a file system provider contract covering list, stat, read, write, move, delete, watch, cancellation and capability flags
- [ ] **V2** (L) Move local file access behind the contract, with no behaviour change
- [ ] **V3** (L) Streaming transfers between any two providers
- [ ] **V4** (M) Keychain credential store and connection manager UI
- [ ] **V5** (M) Remote listing cache, offline state and reconnect
- [ ] **V6** (M) Edit remote files: download, watch, upload, with a dirty files panel
- [ ] **V7** (M) Conformance test suite every provider must pass

## Phase 3: Protocols

Each provider is its own pod and can run in parallel. Depends on V7. Dependency reviews come first: no library goes in unread, given the audit history of this project.

- [ ] **P1** (L) SFTP
- [ ] **P2** (M) FTP and FTPS
- [ ] **P3** (M) WebDAV
- [ ] **P4** (L) SMB
- [ ] **P5** (L) S3 and S3-compatible, with multipart upload
- [ ] **P6** (M) Remote commands over SSH, and a process console

## Phase 4: Cloud

Each provider can run in parallel. Depends on V7 and a shared OAuth item.

- [ ] **C10** (M) Shared OAuth client using the system browser, tokens in Keychain. Do this first
- [ ] **C11** (L) Google Drive
- [ ] **C12** (L) Dropbox
- [ ] **C13** (L) OneDrive
- [ ] **C14** (M) iCloud Drive status: download, evict, progress
- [ ] **C15** (M) Box

Each provider needs a developer app registration, owned by the maintainer.

Optional, only on request: Aliyun Drive, Aliyun OSS, Baidu Netdisk, Tencent COS, Qiniu, Upyun.

## Phase 5: Release quality

Can run in parallel with phases 3 and 4.

- [ ] **R1** (M) Developer ID signing, hardened runtime and notarization. Needs an Apple Developer account
- [ ] **R2** (M) Signed updates, if updates return: signature check, no automatic install without consent
- [ ] **R3** (M) Performance suite: large folders, four panes, idle CPU, memory
- [ ] **R4** (M) VoiceOver and keyboard audit
- [ ] **R5** (S) Support for macOS 27
- [ ] **R6** (S) First public release and install guide

## Manual test checklist

Things only a person can judge in the running app. Use `~/nspace-test` files only. Automated checks are not listed here. Tick items as you test them, and add a note when something is wrong.

### Conflicts and transfers

- [ ] Copy a file over an existing one: the panel opens, and Return chooses Keep Both
- [ ] Replace on purpose: the target is replaced and nothing else changes
- [ ] Cancel a large copy: no partial file remains in the target
- [ ] Copy a folder holding a symlink: the link stays a link
- [ ] Try to copy a folder into itself: it is refused with a clear message
- [ ] Move a file to another volume: the source goes only after the copy finishes
- [ ] Move a tagged folder to another volume: its tag, dates and permissions stay

### Drag and drop

- [ ] Drag between panes in list, icon and column views: the cursor matches the action taken
- [ ] Set the drag preference to Move, then drag with Option held
- [ ] Drop onto the Trash folder: refused, with a message

### Trash

- [ ] Move to Trash, then Put Back
- [ ] Put Back when the original name is taken
- [ ] Empty Trash with one item that cannot be deleted: its record stays
- [ ] Undo a Trash whose restore fails, put an unrelated file at the original path, then Redo: the unrelated file stays

### Archives

- [ ] Extract over an existing folder: it asks first, and nothing is overwritten silently
- [ ] Compress files from one folder, then from search results across folders
- [ ] Confirm no password field offers zip encryption for now

### App behaviour

- [ ] Open `hspace://open?path=...` from a browser: it navigates and does nothing else
- [ ] Open a `/net/...` path through `hspace://`: the UI stays responsive
- [ ] Open a terminal from each view mode: it uses your terminal setting
- [ ] Corrupt `bookmarks.json` in a copy of the app data: you get a warning and a kept-aside file
- [ ] Clear history in Settings
- [ ] Enable Reveal takeover, then restore Finder in Settings
- [ ] Corrupt `trash-ledger.json` or `stash.json` in a copy of the app data: a warning names the kept-aside file, and the Full Disk Access prompt does not overlap it
- [ ] Make a restore of default bookmarks fail (read-only app data): the error shows, not "0 restored"

### Needs a decision

- [ ] "Always Move" with Option held (H8): macOS may refuse this drop. Decide what the preference should do. It also copies across volumes, despite its name
- [ ] Grant Full Disk Access to the debug build, rerun `scripts/ui-smoke.sh`, and confirm the five Trash checks pass (H9)

### Batch tools

- [ ] Batch Rename (⇧⌘R) on ten files: type a replace, add a number step, and the preview follows each key
- [ ] Rename onto a name already in the folder: the row is red, Rename stays disabled, and nothing changes
- [ ] Swap two names with Replace, then press ⌘Z once: both come back; ⇧⌘Z repeats it
- [ ] Batch rename in list, icon and column views, with the keyboard only and with VoiceOver: the sheet reads as a form
- [ ] The sheet in light and dark mode: blocked rows stay readable
- [ ] Save a preset, quit, reopen, and load it: the steps come back; delete it from the same menu
- [ ] Quick Rename on three files: edit the lines, paste a list over them, then ⌘Return; a wrong line count is explained in place
- [ ] Rename Log after a restart: Undo reverses an old batch; move a file away first and it refuses with a clear message

- [ ] File Hash on a large file: the bar moves, Cancel stops it at once, and the digest matches `shasum -a 256`
- [ ] Paste a digest copied from a download page: the matching cell turns green; in dark mode too

- [ ] Convert a folder of photos to JPEG at 50%: progress moves, Cancel stops after the current image, and the originals are untouched
- [ ] Convert a photo taken in portrait: it stays upright. Convert an animated GIF to GIF: it still plays
- [ ] Convert to a folder on a nearly full drive: a clear error, and no hidden leftovers in that folder
- [ ] ⌘Z after converting: the new files go to the Trash and the originals stay; ⇧⌘Z brings them back

### Overall feel

- [ ] Interface density and appearance compared with QSpace
- [ ] Speed in a large folder
- [ ] Idle CPU with four panes open

## Not planned

- Payment, activation, invitations, accounts and other QSpace licensing features
- Making HSpace the default handler for folders: macOS 26 and later keep this for Finder. Reveal takeover and Services remain the supported paths

## Sources and limits

The QSpace feature list comes from QSpace Pro 7.0.4 bundle metadata: frameworks, class names, localized resources and its scripting definition. The list says what exists, not how well it works, so check each lane against the real app before designing it. Implementations must come from observed behaviour and our own design.
