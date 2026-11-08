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

- [x] **L01** (M) Finder tags: read, set, filter, sort and a tag picker
- [x] **L02** (S) Finder comments
- [x] **L03** (M) File colours and rules
- [x] **L04** (M) Custom folder icons and emoji, folder styles
- [x] **L05** (M) Kind groups with a manager
- [x] **L06** (S) Set default app per file kind

### Lane 2: Batch tools

New pods `BatchRename`, `FileHash`, `ImageConvert`.

- [x] **L10** (L) Batch rename: processors, sequence, date, case, replace, preview and collision check
- [x] **L11** (M) Batch rename presets and logs, with undo
- [x] **L12** (S) Quick rename variant for a few files
- [x] **L13** (M) File hash: MD5, SHA-1, SHA-256, compare, cancel
- [x] **L14** (M) Image conversion and resize. Vision-based actions stay a later option
- [x] **L15** (M) Match and select by pattern
- [x] **L16** (S) Text processing of selected names
- [x] **L17** (S) Merge and flatten folders, depends on A8

### Lane 3: Viewing

Owns the view controllers and `Sources/Pods/IconThumb`.

- [x] **L20** (L) Side preview panel, with configurable actions
- [x] **L21** (L) File inspector panel
- [x] **L22** (M) View options per folder, and saved view styles with a manager
- [x] **L23** (M) Custom hidden items and exclusion rules
- [x] **L24** (M) Folder sizes in list view, with a setting
- [x] **L25** (M) Icon view options: size, spacing, label position
- [x] **L26** (S) Keyboard selection with Space
- [x] **L27** (M) Photos library browsing

### Lane 4: Navigation

Owns `BreadcrumbBar.swift`, `PathEditorField.swift`, `SidebarViewController.swift`, `TabBarView.swift`.

- [x] **L30** (M) Recent tab switcher
- [x] **L31** (M) Quick locations and go-to-bookmark panel
- [x] **L32** (M) Quick launcher with commands
- [x] **L33** (M) Sidebar item accent colours and palettes
- [x] **L34** (M) Tab drag-out and reorder
- [x] **L35** (S) Bring to active Space, drag-shake gesture

### Lane 5: Operations

Owns a new `Scheduler` pod and `ProgressWindowController.swift`. Depends on track A. L41 and L42 depend on L40.

- [x] **L40** (L) Scheduler: queue, priorities, per-path locks, pause and resume
- [x] **L41** (M) Task list window and toolbar status
- [x] **L42** (M) Operation history with undo groups
- [x] **L43** (L) Local folder sync: compare, filters, presets, direction, dry run. Must show a plan before any delete
- [x] **L44** (M) New file templates, with `$date(format)` names

### Lane 6: Archives

Owns `Sources/Pods/ArchiveEngine`. Depends on track B.

- [x] **L50** (L) Browse inside archives without extracting
- [x] **L51** (M) Quick Look inside archives
- [ ] **L52** (L) 7z and RAR extraction, after a license and dependency review. Plain 7z and RAR work through the system `tar`; left open for the owner's choice in the review below.
- [x] **L53** (M) Compression settings and password list stored in Keychain

#### Review for L52: 7z and RAR

No dependency was added. Checked on macOS 26 (Darwin 25.5) with `/usr/bin/tar`, which is bsdtar 3.5.3 on libarchive 3.7.4. What is in place:

| Case | Status without a dependency |
|---|---|
| 7z: browse, Quick Look, extract | Works. The tests create archives with `tar --format=7zip` |
| RAR 4 and RAR 5: browse, Quick Look, extract | Works on stored data, tested with fixtures built byte by byte. Compressed RAR needs a real-world archive, see the manual checklist |
| RAR with encrypted entries | Refused by tar on compressed data, and the error reaches the user. Tested with a RAR 4 fixture. An encrypted entry stored without compression passes that check and should fail on its checksum: not tested on a real file |
| Password-protected 7z, or 7z with encrypted names | Not supported by libarchive, as far as its source goes. Not tested: no tool here can create one |
| Split archives (`.part1.rar`, `.r00`, `.7z.001`) | Not supported: `tar -f` opens one file. `.r00` and `.7z.001` are not offered. `.part1.rar` is offered and should fail at the volume's end: not tested on a real file |
| Creating RAR | Impossible without RAR's own software, and out of scope |

Other tools on the system: `xar` and `unzip` read neither format. There is no `7z`, `7zz`, `unrar` or `unar` on a stock Mac. Apple ships libarchive as a library without headers; linking it would bring passwords for zip only, run hostile data inside the app process, and rely on an undocumented API, so that route is rejected.

Limit of the current route: this behaviour is not documented by Apple, so a macOS update could change the formats tar reads. A failure then shows as an error, and tests catch it.

**The owner must choose** how far to go for encrypted and split 7z and RAR. Licence notes are from memory of the projects' terms; read the current text before shipping anything.

1. **Stay with the system `tar`.** Nothing to ship or maintain. Encrypted and split archives stay unsupported, and L52 closes with that recorded as a known gap.
2. **Use a tool the user installed** (`7zz` or `unar` from Homebrew), looked up in known locations, and offered only when found. Nothing to ship and no licence impact. The app starts trusting a binary outside `/usr/bin`, and the feature differs between machines.
3. **Bundle 7-Zip's `7zz`.** Covers everything for reading. LGPL 2.1 with a BSD part, plus the unRAR restriction: its RAR code must not be used to create a RAR compressor. As a separate process in an MIT app this is workable, with notices and source pointers. Costs: signing and notarizing a third-party binary, and security updates become ours. It needs an exception to "no third-party dependencies".
4. **Bundle `unar`.** LGPL, covers RAR and 7z with passwords, but its release pace is slow, which matters for a parser fed hostile files. Same costs as option 3.

Suggested: option 1 now, and option 3 only if encrypted RAR or 7z turns out to be a real need.

### Lane 7: System integration

Owns new app extension targets. L60 and L61 need a proper Xcode target or an equivalent build step.

Build step, no Xcode needed: each extension is a plain SwiftPM executable whose main hands over to `NSExtensionMain`. `scripts/build-app.sh` wraps every folder under `Support/Extensions` (its Info.plist and sandbox entitlements) into `Contents/PlugIns/<name>.appex` and signs it before the app. `scripts/check-bundle.sh` checks the result in CI and in the release job. Extensions read what the app publishes in `Application Support/HSpace/Extensions` (ExtensionBridge pod) and ask for work only through `hspace://stash` links that carry its secret.

- [x] **L60** (L) Finder Sync extension with badges
- [x] **L61** (M) Share extension for the stash
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
- [ ] Compress with Password: the zip opens here with that password, and a wrong password asks again
- [ ] Extract a password zip with its password saved in Settings > Archive: no question is asked
- [ ] Tick Save in Keychain, then find the item "HSpace archive passwords" in Keychain Access, and no password anywhere in `~/Library/Preferences`
- [ ] After a rebuild, macOS asks once to let the new build read the Keychain item (ad-hoc signature); Always Allow works
- [ ] Remove a saved password: it asks first, and the item goes from Keychain Access with the last one
- [ ] Compression level: None gives a larger archive than Best, for zip and tar.gz
- [ ] Browse a password zip: Quick Look and Extract To ask for the password once per window
- [ ] Right-click a zip and a tar.gz, Browse Archive: the tree, sizes and dates match the content, and the file on disk does not change
- [ ] In the browser, select a file and a folder, Extract To: only those land, and a name already taken asks first
- [ ] Extract To with nothing selected extracts the whole archive
- [ ] Open a large tar.gz in the browser and press Cancel or Escape: reading stops
- [ ] The browser works with VoiceOver and the keyboard, in light and dark mode
- [ ] In the browser, press Space on an image, a PDF and a text file: each previews, and arrows page through the list
- [ ] Double-click a file in the browser: it previews. Press Space on a folder: only a beep
- [ ] Close the browser: no `hspace-archive-` folder stays in the temporary directory
- [ ] Browse and extract a real `.rar` made by WinRAR (compressed, both RAR 4 and RAR 5) and a real `.7z` made by 7-Zip: tests cover stored RAR data only
- [ ] Open an encrypted `.7z` and an encrypted `.rar`: a clear error, nothing lands
- [ ] Extract a `.part1.rar`: a clear error, nothing lands

### App behaviour

- [ ] Open `hspace://open?path=...` from a browser: it navigates and does nothing else
- [ ] Open a `/net/...` path through `hspace://`: the UI stays responsive
- [ ] Open a terminal from each view mode: it uses your terminal setting
- [ ] Corrupt `bookmarks.json` in a copy of the app data: you get a warning and a kept-aside file
- [ ] Clear history in Settings
- [ ] Enable Reveal takeover, then restore Finder in Settings
- [ ] Corrupt `trash-ledger.json` or `stash.json` in a copy of the app data: a warning names the kept-aside file, and the Full Disk Access prompt does not overlap it
- [ ] Make a restore of default bookmarks fail (read-only app data): the error shows, not "0 restored"

### File metadata

- [ ] Tag a file here, then open Get Info in Finder: same tags and colours. Tag one in Finder: HSpace shows it after a moment
- [ ] Remove the last tag here: Finder shows none, not a leftover colour
- [ ] Tag dots look right in list, icon and column views, in light and dark mode, and on a selected row
- [ ] Edit Tags sheet with several items selected: a tag on some items shows a dash, and leaving it alone changes nothing. Tab and Return work, and VoiceOver reads each tag
- [ ] Filter by Tag and Sort by Tags from the empty-space menu in all three views. The "Tagged" pill clears the filter in one click
- [ ] Tags column in the list: shows in the header menu and sorts on click
- [ ] Undo and Redo a tag change with ⌘Z and ⇧⌘Z
- [ ] Tag a few thousand items: the progress sheet appears, and Cancel leaves them all unchanged
- [ ] Edit Comment on a file: macOS asks once to let HSpace control Finder. Allow it, then Finder's Get Info shows the comment
- [ ] Refuse that request, then edit a comment: a toast says Finder may show the old one, and the comment is still saved here
- [ ] Comment column in the list, and the Comment line in Get Info. With several items selected and differing comments, the sheet says so
- [ ] A comment set in Finder shows here, and Undo restores the old comment in both places
- [ ] File Color from the context menu: the name is coloured in list, icon and column views, in light and dark mode, stays readable on a selected row, and Undo works
- [ ] Settings, File Colors: add, edit, reorder, disable and remove a rule. Open rows recolour at once, and the page fits the window
- [ ] Corrupt `file-metadata.json` in a copy of the app data: a warning names the kept-aside file
- [ ] Folder Icon with a colour, an emoji, both, and a picture: the preview matches, the list, icon and column views show it, and so does Finder
- [ ] Emoji Picker button opens the system picker and the chosen emoji lands in the field
- [ ] Remove Custom Icon, and Undo and Redo of an icon change
- [ ] Set an icon on a folder in a read-only location: a toast explains the failure
- [ ] Sort by Kind with Use Groups on, in list and icon views: headers show the kind groups in the manager's order, with Other last
- [ ] Right-click a kind header, Show Only This Group, then Show All Groups
- [ ] Settings, Kind Groups: rename, edit matches, reorder, add and remove. Open panes regroup at once. Reset to Defaults asks first
- [ ] Open With, Always Open With: it asks first, then a double-click and Finder both use the new app. Undo puts the old app back
- [ ] Always Open With, Other: choose an app outside the list
- [ ] Always Open With is absent for folders and for files of an unknown kind

### Needs a decision

- [ ] "Always Move" with Option held (H8): macOS may refuse this drop. Decide what the preference should do. It also copies across volumes, despite its name
- [ ] Grant Full Disk Access to the debug build, rerun `scripts/ui-smoke.sh`, and confirm the five Trash checks pass (H9)
- [ ] Encrypted and split 7z or RAR archives (L52): pick an option in the review under Lane 6. Suggested: stay with the system `tar` and record the gap

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

- [ ] Select by Pattern with `*.jpg; *.png` in list, icon and column views: the count is live, and the status bar shows the new selection
- [ ] Add to and remove from a selection with the same sheet; a bad regular expression is explained in place

- [ ] Batch Tools > Text Processing > Remove accents: the rename sheet opens with the preview ready; Rename, then ⌘Z restores
- [ ] Copy Names on several items, paste into a text editor: one name per line

- [ ] Merge two folders holding a same-named subfolder and a same-named file: the panel asks for each, and Merge combines the subfolders
- [ ] Skip a clash during a merge: that folder stays, with the skipped file in it
- [ ] Flatten a nested folder: same-named files become "name 2", and the empty subfolders are in the Trash, restorable with ⌘Z
- [ ] Flatten across an unreadable subfolder: a clear error before anything moves

### Operations

- [ ] Copy a large folder and a second one to another folder at the same time: both progress
- [ ] Copy into a folder, then rename an item being replaced there: the rename waits for the copy
- [ ] Two copies with conflicts: one panel at a time
- [ ] The tasks icon shows a count and a tooltip while work runs, and goes back to plain when idle; idle CPU stays at 0
- [ ] Pause a cross-volume copy mid-file: bytes stop within a moment; Resume continues, Cancel leaves nothing
- [ ] Pause All with a copy running and one queued, then add a third: nothing starts until Resume All
- [ ] With 1 at once, queue two copies and set the second to High: it runs next
- [ ] A failed task stays in the list until Clear Finished; finished ones go by themselves
- [ ] Window > Operation History after a copy, a move, a rename and a Trash: each is listed, and Undo takes each back, also after a restart
- [ ] Undo a copy: the copy goes to the Trash. Undo a copy that merged into a folder: the folder stays
- [ ] Undo a move when the original place is taken: nothing changes, and the sheet says why
- [ ] Flatten a folder, then Undo its one history line: the files return and the emptied folders come back
- [ ] Folder Sync in `~/nspace-test` with Dry Run on: Compare lists every action, Dry Run reports them, and no file changes
- [ ] Mirror with Dry Run off: the delete question lists the extras, Return does nothing, and Cancel leaves everything
- [ ] After a Mirror, Compare again: nothing to do. Undo its one history line: everything is back, the extras too
- [ ] Mirror from an empty folder: the warning names the risk of a wrong folder or an unmounted volume
- [ ] Edit a file after Compare, then Sync: it is left alone and the report says so
- [ ] Sync with an unreadable subfolder: the summary says so, and the plan holds no delete
- [ ] Cancel during Compare with Contents on a large folder, and during Sync: it stops, and a second Compare shows what is left
- [ ] Save a preset with folders, reopen the sheet, choose it: everything returns. Delete Preset removes it
- [ ] Save a file as a template, name it `Log $date(yyyy-MM-dd).md` in the templates folder: the menu shows today's name, and New from Template selects it for renaming
- [ ] New from Template twice in one folder: the second gets "2", with no panel. A folder template copies whole
- [ ] New from Template in list, icon and column views, from the File menu and the right-click menu; grayed out in the Trash
- [ ] The task list works in light and dark mode, and with VoiceOver: Pause, Priority and Cancel are named

### Viewing

- [ ] View > Preview Panel (⌥⌘P): the panel opens right of the panes and previews the selection in list, icon and column views; the window size stays
- [ ] Arrow quickly through a folder of large files: the preview keeps up and nothing stutters
- [ ] Preview a video: it waits for play. Hide the panel while it plays: the sound stops
- [ ] Select several items: a count and size show. Clear the selection: "No selection"
- [ ] Drag the panel's left edge: it stops at its limits, and the width survives a restart
- [ ] Settings > Side Panel: turn actions off, reorder them; the panel follows at once. Reset brings the defaults back
- [ ] Panel buttons act on the selection of the active pane, and gray out in the Trash where the menus do. Move to Trash can be undone
- [ ] The panel looks right in light and dark mode, and VoiceOver names each button
- [ ] View > Inspector Panel (⌥⌘I): facts of the selection, or of the folder with nothing selected. With the preview on too, each takes half the column
- [ ] Inspect an image, a video, a PDF, a symlink and a broken symlink: dimensions, duration, pages, target and "missing" show
- [ ] Select a big folder: "Calculating…", then the size. Move on while it counts: it stops, with no CPU left running
- [ ] Select several items with a folder among them: the total arrives, or says "At least" when part cannot be read
- [ ] Values can be selected and copied; VoiceOver reads each with its label
- [ ] View > View Options > Remember for This Folder: set icons sorted by size, leave, come back: the view returns. Other folders keep the pane's own view, also after Back
- [ ] Include Subfolders: subfolders follow, until one has its own rule
- [ ] Change the view in a remembered folder: the change sticks. Quit and reopen: it is still there
- [ ] Save View as Style, apply it elsewhere from the menu. A duplicate or blank name is refused with a message
- [ ] Manage Styles: rename, remove (asks first), forget a folder; keyboard and VoiceOver work in the sheet
- [ ] Right-click > Hide: the item goes in every view mode, and ⌘Z brings it back. Show Hidden Files shows it dimmed
- [ ] Settings > Hidden Items: add `*.log`: open panes update at once. Set it to Exclude: Show Hidden Files no longer brings it back
- [ ] A rule with a scope applies in that folder and below only. Clearing a pattern says what is wrong and keeps the old rule on disk
- [ ] Nothing changes in Finder: the rules only change what HSpace shows
- [ ] List view: visible folders show "…", then their size. Scroll a big folder off screen: the walk stops
- [ ] Settings > Behavior > Folder sizes: Never shows "—" at once; Local volumes only leaves a network share alone; All folders walks it
- [ ] Hide the Size column: no folder is walked
- [ ] A folder without permission shows "—" and is not retried while you scroll
- [ ] Select a folder whose size is known: the status bar total includes it. Sorting by size still orders folders by name, since most sizes are unknown at that moment
- [ ] Icon view: the slider runs from 32 to 256; images stay sharp when large
- [ ] The button beside the slider, and View > View Options > Icon Options: spacing changes at once, and Name Beside Icon reflows the grid; the selection stays
- [ ] Both also work grouped by date, in light and dark mode, and with a long file name in two lines
- [ ] Remember a folder in icon view with its own size and spacing: another folder keeps the general setting
- [ ] Icon Options are gray in list and column views
- [ ] Settings > Behavior: turn on "Space selects items". In list, icon and column views, Space toggles the item and moves on; an outline shows the next item; arrows move the outline and keep the selection
- [ ] A click, or an arrow with no outline showing, returns to normal selection. Group headers are skipped
- [ ] With the setting on, Shift-Space previews, and Space closes an open preview. With it off, Space previews as before
- [ ] In column view, picking one folder with Space opens its column, like a click; the cursor stays in the column you are in
- [ ] The outline stays visible in light and dark mode
- [ ] Go > Photos Library on a fresh permission: a message and Allow Access. The system prompt appears only after pressing it, and it gives the reason from Info.plist
- [ ] Don't Allow: the window explains, Open System Settings goes to the Photos pane, and allowing there works when you return to the window
- [ ] Allowed: albums on the left, thumbnails on the right, with a mark on videos; scrolling a large library stays smooth and downloads nothing
- [ ] Select several, Copy to Active Pane: originals arrive in the active pane's folder under their own names; a taken name gets a number
- [ ] An item stored only in iCloud downloads and arrives. Cancel during a copy: only finished files remain, no partial file
- [ ] Limited access shows only the chosen photos. The library in Photos is unchanged. VoiceOver reads kind and date

### Navigation

- [ ] With several tabs open, hold Option and press Tab: after a moment a panel lists tabs by last use; each Tab steps, Shift-Tab steps back, and releasing Option switches. A quick press and release swaps the last two tabs with no flash
- [ ] Esc while the panel shows stays on the current tab, and a click on a row switches to it. Window > Recent Tabs stays open until Return, Esc or a click, and works with arrow keys
- [ ] The panel reads well in light and dark mode, and VoiceOver announces each tab as you step
- [ ] Go > Quick Locations (Shift-Command-G): bookmarks, iCloud, volumes and recent folders appear; typing filters, also by abbreviation; arrows move, Return goes, Esc or a click elsewhere closes and focus returns to the pane
- [ ] Type /usr/bin or ~/Documents: a Go to Path row comes first. A path to a file opens its folder with the file selected. A path that does not exist says so
- [ ] Command-Return opens the location in a new tab. Go > Go to Bookmark (Option-Command-B) lists bookmarks only
- [ ] A deleted folder never shows as recent, and a bookmark deleted while the panel is open shows a message instead of an empty pane
- [ ] Panel reads well in light and dark mode; VoiceOver names the field and reads the rows
- [ ] Go > Quick Launcher (Shift-Command-P): recently used commands come first, then the rest. Typing finds menu commands with their menu path and shortcut, and locations in the same list
- [ ] A command that the menus gray out right now, such as Duplicate with nothing selected, is not offered. Return runs a command in the active pane, in list, icon and column views
- [ ] Start with > and only commands remain. A path or a location still goes there, and Command-Return opens it in a new tab
- [ ] After restart, recent commands are still first
- [ ] Right-click a bookmark, iCloud or a volume: Color lists system colours with swatches and None. A choice tints that row's icon at once in every window, and the current colour is ticked
- [ ] A folder with a real file icon, and a volume, switch to a symbol that shows the colour; None brings the real icon back
- [ ] Sidebar Palette, from the right-click menu or Settings > Appearance: Spectrum, Cool, Warm and Monochrome colour every row, and an item's own colour stays. Standard returns to the usual look
- [ ] Colours survive a restart and a moved bookmark folder. They read well in light and dark mode, and selected rows stay legible
- [ ] Clicking a tab still switches on the first click, also when coming from another app. Dragging a tab along the strip shows a mark in the gap, and dropping moves it; the same workspace stays active
- [ ] Drag a tab clear of the window and release: it opens in its own window at that spot, with its panes and paths. Dragging onto the window itself, or pressing Esc during the drag, changes nothing
- [ ] Drag a tab to another window's strip: it joins there at the mark. If it was the source window's last tab, that window closes
- [ ] The last tab in a window cannot be dragged out into a new window. File > Move Tab Left, Right and to New Window do the same from the keyboard and gray out when they cannot apply
- [ ] Dragging files onto the tab strip, and tabs onto panes, has no effect. VoiceOver reads each tab and can switch to it. After a restart moved tabs and detached windows come back
- [ ] With a window on another Space: Window > Bring to Active Space, or the same item in the Dock menu, moves all windows here without switching Space. The window then stays on this Space when you change Space
- [ ] Settings > Behavior, Summoning HSpace brings its window: the global hotkey and a Dock click bring the window here. Off, they switch to the window's Space as before. A full-screen window is only raised
- [ ] Settings > Behavior, Shake the pointer: drag files from Finder and shake left and right a few times: HSpace comes to this Space with the sidebar open, and the files drop on the stash shelf
- [ ] Shaking while dragging text or a window does nothing, and a slow drag does not trigger it. Check a shake during a drag started inside HSpace too
- [ ] With the shake setting off, and with it on at rest, idle CPU stays at 0.0%

### System integration (lane 7a)

- [ ] Build with `scripts/build-app.sh`, open Settings > Permissions > Open Extension Settings, and turn on HSpace under Finder: after Re-check, the status line says it is on
- [ ] Stash a file in HSpace: Finder shows the stash badge on it within a second, and the badge goes when you remove it from the shelf. Badges also follow Clear and Move Here
- [ ] Right-click files in Finder > Add to HSpace Stash: they land on the shelf of the front window, and a toast counts them. With HSpace quit, HSpace opens and stashes them
- [ ] Right-click a folder, a file and the background of a Finder window > Open in HSpace: the folder opens, the file shows selected in its folder. The HSpace toolbar button does the same, once added through View > Customize Toolbar
- [ ] Open `hspace://stash?path=/tmp` from a browser: nothing is stashed, and a message says the link is not from HSpace
- [ ] With the extension on, Finder's CPU stays at rest when nothing changes, and HSpace's idle CPU stays at 0.0%
- [ ] Turn on HSpace Stash under Sharing in the extension settings. In Finder, select files and a folder, Share > HSpace Stash: the sheet names what will be stashed, Add puts them on the front window's shelf, and Cancel or Esc adds nothing
- [ ] Share a file from another app, such as Preview: it lands on the shelf too. Sharing only text or a web page from Safari does not offer HSpace Stash, or says only files can be stashed
- [ ] Before HSpace has ever run, Share > HSpace Stash > Add says to open HSpace first. The sheet reads well in light and dark mode and works with VoiceOver and the keyboard

### Overall feel

- [ ] Interface density and appearance compared with QSpace
- [ ] Speed in a large folder
- [ ] Idle CPU with four panes open

## Not planned

- Payment, activation, invitations, accounts and other QSpace licensing features
- Making HSpace the default handler for folders: macOS 26 and later keep this for Finder. Reveal takeover and Services remain the supported paths

## Sources and limits

The QSpace feature list comes from QSpace Pro 7.0.4 bundle metadata: frameworks, class names, localized resources and its scripting definition. The list says what exists, not how well it works, so check each lane against the real app before designing it. Implementations must come from observed behaviour and our own design.
