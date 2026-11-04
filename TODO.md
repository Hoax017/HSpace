# HSpace TODO

> Forward plan and feature parity tracking: see [ROADMAP.md](ROADMAP.md).

New requests go here first. Nothing is in progress right now. History and the detail behind each item are in `CHANGELOG.md`.

## Open

- ⬜ **I-63** Emptying the Trash on several volumes at once: each volume is emptied separately today (v0.19.19). Deferred until a real failure calls for it.
- ⬜ **M17** Drag a workspace tab out into its own window: deferred to v2 when native tabbing was dropped (see Workspace tabs in the M17 spec). Drag-to-reorder for workspace tabs was optional and is also not built.
- ⬜ **I-06** Optional setting for what double-clicking an archive does (system default app, or extract in HSpace). Today it always opens with the system default.
- ⬜ **I-56** Accessibility labels: the codebase has none. Only path errors are announced to VoiceOver; broader work should be planned as a project, not as isolated fixes (v0.19.10).

## v2 backlog

The architecture leaves pod slots for these:

- Batch rename
- Archive browsing (compression shipped in v0.8.0)
- File hashing
- Folder sync
- Colouring rules
- Workspace global shortcuts
- FTP, SFTP, S3, WebDAV and cloud drives
- QSpace-style desktop
- Quick launch

## Standing rules

- Icons are SF Symbols and NSWorkspace file icons only, never emoji or text. Each has a 150ms tooltip.
- Front-end method: surgical-instrument metaphor (full keyboard reach, hairline borders, hover-reveal, 4pt grid, in-place resolution, no fake buttons, FG-1).
- Versioning: `VERSION`, `CHANGELOG.md` and a git tag per milestone, with the version injected at build time.
- Every milestone: meta-doctor exits 0, tests are green, real-machine screenshots are checked, then a green commit.
- Public asset hard rule (after I-35): screenshots, sample data and docs entering the public repository pass `scripts/sanitize-check.sh` (forced at pre-push; the `.sanitize-terms` list stays local) and a human check. Real folder content is only shown through the `HSPACE_UITEST_DEMO` fixture.
- Test sandbox hard rule: automated tests never touch real user files. Mutations happen only in self-made temporary fixtures (`temporaryDirectory/hspace-uitest-*`, always cleaned up), enforced by `UISelfTest.assertSandboxed`.

## Completed milestones

- ✅ M0 Meta-architecture compliance and the Xcode-free SwiftPM build
- ✅ M1 Engine slice: OperationKernel, DirectoryReader, Transfer, `hspace-probe`
- ✅ M2 Single-pane list view
- ✅ M3 Address bar and history
- ✅ M4 Multi-pane layouts and pane focus cycling
- ✅ M5 Sidebar (v0.5.0)
- ✅ M6 File operations UI (v0.5.0)
- ✅ M7 Drag and drop, stash shelf (v0.6.0)
- ✅ M8 Quick Look, Get Info, Open With (v0.7.0)
- ✅ M9 Icon, list and column views (v0.7.0)
- ✅ M10 Live refresh and performance (v0.6.0)
- ✅ M11 Settings, session restore, Finder integration, README (v0.7.0)
- ✅ M12 Spotlight search with a hidden-files channel (v0.7.0)
- ✅ M13 Window-level workspace tabs (v0.6.0); pane tabs retired in v0.19.26
- ✅ M14 Stash rework and icon-only actions (v0.7.0, sweep finished in v0.10.0)
- ✅ M15 Toast feedback, Add to Bookmarks, iTerm first (finished in v0.10.0)
- ✅ M16 Feedback batch I-06 to I-10 (v0.9.0)
- ✅ M17 Custom top deck and full-height sidebar (v0.9.0)
- ✅ M18 Grid convergence, baseline deleted (v0.10.0)
- ✅ M19 All shortcuts in the registry (v0.10.0)
- ✅ M20 App icon (v0.9.2)
- ✅ M21 Finish polish (v0.10.0)
- ✅ M22 Version badge and self-update (v0.10.0); the self-updater was removed in the fork
- ✅ M23 Full-feature test matrix (v0.11.0)
- ✅ M24 Global show/hide hotkey (v0.13.0)
- ✅ M25 Open source and Release CI (v0.14.0)
- ✅ M26 Date grouping and group filter (v0.15.0 list, v0.18.0 icons)
- ✅ M27 Conflict experience (v0.17.0)
- ✅ M28 Habit-learning search ranking (v0.19.0)
- ✅ M29 Human-friendly time (v0.18.3)
- ✅ All issues through I-74 are closed, apart from the follow-ups listed under Open
