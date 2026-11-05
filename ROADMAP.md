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

- [ ] **A1** (L) Atomic replace: copy to a temporary name, then swap, so a failed copy keeps the old target. `InternalEngine.swift:75`
- [ ] **A2** (M) Stop treating unreadable folders as empty, which can delete the source on a cross-volume move. `InternalEngine.swift:119`
- [ ] **A3** (M) Delete the source of a cross-volume move only after verifying the copy. `InternalEngine.swift:97`
- [ ] **A4** (M) Block a folder moved or copied into itself, and moves that replace a parent of the source. `InternalPlan.swift:166`
- [ ] **A5** (M) Preserve symlinks as symlinks, handle cycles and dangling links. `InternalEngine.swift:109,206`
- [ ] **A6** (S) Copy with `COPYFILE_EXCL` so a file that appears after the conflict check is not overwritten.
- [ ] **A7** (M) Remove partial output when a folder copy is cancelled.
- [ ] **A8** (S) Make merge replace file over file only, as its contract says. `InternalEngine.swift:128`

### Track B: Archives

Owns `Sources/Pods/ArchiveEngine`.

- [ ] **B1** (M) Extraction must not delete an existing item without asking. `InternalArchive.swift:177`
- [ ] **B2** (S) Pass `--` before file names so a name starting with `-` is not read as an option; check zip `-TT` exposure. `InternalArchive.swift:59,63`
- [ ] **B3** (S) Read process pipes while running to avoid a hang on large output. `InternalProcess.swift:35,71`
- [ ] **B4** (M) Stop putting passwords on the command line, and stop accepting a password for tar.gz. `InternalArchive.swift:58,62,141`
- [ ] **B5** (S) Handle selections from several folders. `InternalArchive.swift:24`

### Track C: Trash and recovery

Owns `FileOpsCoordinator.swift`, `Sources/Pods/Eraser`, `Sources/Pods/TrashLedger`.

- [x] **C1** (S) Use the move receipt in restore, so a failed move cannot rename an unrelated file. `FileOpsCoordinator.swift:408`
- [x] **C2** (S) Keep the Put Back record until restore succeeds. `FileOpsCoordinator.swift:198`
- [x] **C3** (S) Keep Put Back records for items that failed to delete. `FileOpsCoordinator.swift:175`
- [x] **C4** (M) Apply the "not into Trash" guard to drops, F5/F6 and the stash. `FileOpsCoordinator.swift:351`
- [x] **C5** (S) Keep ledger entries for unmounted volumes. `TrashLedger/Node.swift:80`
- [ ] **C6** (S) Resolve symlinks in the Eraser fence check. `Eraser/Contract.swift:27`

### Track D: Saved data

Owns `Sources/Pods/BookmarkStore`, `StashStore`, `SessionStore`.

- [ ] **D1** (M) A corrupt JSON file must be kept aside and reported, never overwritten. `TrashLedger/Node.swift:73`, `StashStore/Node.swift:74`, `BookmarkStore/Node.swift:128`
- [ ] **D2** (S) Report failed bookmark writes instead of showing success. `MainWindowController.swift:316`
- [ ] **D3** (S) Add a way to clear the local history of opened paths. `Sources/Pods/Frecency`

### Track E: App entry points

Owns `AppDelegate.swift`, `FinderIntegration.swift`, `UISelfTest.swift`.

- [ ] **E1** (M) Harden `hspace://`: separate open from reveal, reject network and automount paths, do no blocking work on the main thread. `AppDelegate.swift:183`
- [ ] **E2** (M) Compile `UISelfTest` and all environment test hooks out of release builds. `AppDelegate.swift:34`, `UISelfTest.swift:11`
- [ ] **E3** (M) Isolate test runs from real preferences, bookmarks, stash and clipboard. `MainWindowController.swift:46`, `AppDelegate.swift:140`
- [ ] **E4** (S) Provide a way to restore the system Reveal setting. `FinderIntegration.swift:69`
- [ ] **E5** (S) Stop storing the last opened path in defaults. `AppDelegate.swift:206`

### Track F: Interaction safety

Owns `ConflictSheet.swift` and the drop handlers in the three view controllers.

- [ ] **F1** (S) Replace must not be the Return default. `ConflictSheet.swift:216`
- [ ] **F2** (S) Drop feedback must match the action taken. `FileIconGridViewController.swift:838`, `FileColumnViewController.swift:351`
- [ ] **F3** (S) Honour the terminal setting in all view modes. `FileIconGridViewController.swift:663`

### Track G: Engineering

Owns `.github`, `scripts`, docs.

- [ ] **G1** (M) Run build, tests and lints on every pull request.
- [ ] **G2** (S) Pin workflow actions to commit hashes, and restrict token permissions. `release.yml:15,36`
- [ ] **G3** (S) Install the pre-commit checks the docs promise, or remove the claims.
- [ ] **G4** (S) `ui-smoke.sh` must not kill a running HSpace. `ui-smoke.sh:7`
- [ ] **G5** (S) Fix `build-app.sh` path handling and `run.sh` install order. `build-app.sh:48`, `run.sh:8`
- [ ] **G6** (S) Correct the docs where they disagree with the code: `spec.md`, `PRODUCT.md`, `DESIGN.md`, `README.md`.
- [x] **G7** (S) Add a failure-injection test helper shared by tracks A to D. Do this first.

**Gate 0:** tracks A to F closed and G1 in place. No Phase 1 work merges before this.

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

- [ ] **L10** (L) Batch rename: processors, sequence, date, case, replace, preview and collision check
- [ ] **L11** (M) Batch rename presets and logs, with undo
- [ ] **L12** (S) Quick rename variant for a few files
- [ ] **L13** (M) File hash: MD5, SHA-1, SHA-256, compare, cancel
- [ ] **L14** (M) Image conversion and resize, with Vision-based actions as a later option
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

## Not planned

- Payment, activation, invitations, accounts and other QSpace licensing features
- Making HSpace the default handler for folders: macOS 26 and later keep this for Finder. Reveal takeover and Services remain the supported paths

## Sources and limits

The QSpace feature list comes from QSpace Pro 7.0.4 bundle metadata: frameworks, class names, localized resources and its scripting definition. The list says what exists, not how well it works, so check each lane against the real app before designing it. Implementations must come from observed behaviour and our own design.
