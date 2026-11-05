---
name: HSpace
description: A native macOS multi-pane file manager. Finder's material language × QSpace's density, with character coming from structure and craftsmanship, not color
colors:
  # Values = AppKit semantic color identifiers (the sole authority, resolved dynamically for light/dark); no hardcoded hex brand colors.
  ink-primary: "labelColor"          # first-level ink (body text/active state)
  ink-secondary: "secondaryLabelColor"  # second-level ink (secondary info/default icon tint)
  ink-muted: "tertiaryLabelColor"    # third-level ink (placeholder/missing/units)
  hairline: "separatorColor"         # hairline separator
  surface-window: "windowBackgroundColor"
  surface-control: "controlBackgroundColor"
  surface-selected: "selectedContentBackgroundColor"  # selected list row (system state)
  accent: "controlAccentColor"       # = Theme.accent default; users can override it from an 8-color palette
  error: "systemRed"                 # in-place error banner
typography:
  title:
    fontFamily: "system (-apple-system / SF Pro)"
    fontSize: "13px"
    fontWeight: 400
  body:
    fontFamily: "system (-apple-system / SF Pro)"
    fontSize: "12px"          # list/cell default; Preferences.listFontSize configurable 11–14
    fontWeight: 400
  label:
    fontFamily: "system (-apple-system / SF Pro)"
    fontSize: "11px"          # chrome such as deck/status bar/tabs/group headers
    fontWeight: 400
  caption:
    fontFamily: "system (-apple-system / SF Pro)"
    fontSize: "10px"          # sidebar row subtitle (capacity)
    fontWeight: 400
  numeric:
    fontFamily: "system monospaced-digit"
    fontSize: "12px"
    fontWeight: 500           # stash shelf count pill (tabular-nums, digits don't jump)
rounded:
  tab: "5px"      # workspace tab capsule
  pill: "8px"     # count pill / hover float bar / drop ring
spacing:
  optical: "2px"  # optical/hairline fine-tuning (exempt, not on the 4pt scale)
  xs: "4px"
  sm: "8px"
  md: "12px"
  lg: "16px"
  xl: "20px"
  row: "24px"       # address bar/status bar/sidebar row
  tab-row: "40px"   # workspace tab bar / traffic-light row
  toolbar-row: "36px"  # icon toolbar
components:
  workspace-tab-active:
    backgroundColor: "{colors.accent}"   # @ 18% alpha (see the accent ladder under Colors)
    textColor: "{colors.ink-primary}"
    rounded: "{rounded.tab}"
    height: "28px"
  workspace-tab-inactive:
    textColor: "{colors.ink-secondary}"
    rounded: "{rounded.tab}"
    height: "28px"
  icon-button:
    textColor: "{colors.ink-secondary}"  # contentTintColor; SF Symbol pointSize 13 / .regular
    size: "24px"
  count-pill:
    backgroundColor: "{colors.accent}"   # @ 10% alpha
    textColor: "{colors.ink-primary}"
    typography: "{typography.numeric}"
    rounded: "{rounded.pill}"
    height: "16px"
  pane-address-active:
    backgroundColor: "{colors.accent}"   # controlBackgroundColor blended with 10% accent
    height: "24px"
  status-bar:
    backgroundColor: "{colors.surface-window}"
    textColor: "{colors.ink-secondary}"
    typography: "{typography.label}"
    height: "24px"
---

# Design System: HSpace

> A record of the visual system for future contributors and open-source readers. **The real code wins (ground truth over intention)**: wherever measured code differs from the `docs/design/M17-deck-spec.md` spec or the `docs/design/mockup-m17.html` layout mockup, this file records the code as it is and marks the difference at that point.
> New UI must satisfy both the principles in this file and the mechanical `scripts/grid-lint.sh` gate (see Do's and Don'ts).

## Overview

**Creative North Star: "The Surgical Instrument / Structural Worktable"**

HSpace is a native professional macOS file tool, with a visual standard of **Finder's material language × QSpace's information density**. Its identity comes not from color but from **structure, density and craftsmanship**: a hairline running from the top of the window to the bottom, a stash stack pressed against the top of the left column, a three-layer deck in the right column. Strip out all the content and you can still recognize HSpace from this topology alone. The user has explicitly vetoed "flashy web color schemes" (a permanent brand commitment, see PRODUCT.md): the whole system adds zero brand colors and draws entirely on the existing theme system (`Theme.accent`) and macOS semantic colors and system materials.

The character is **restrained, dense, native**. Density is respect for a power user's time: 22pt list rows, font size 12, hairlines instead of borders, distance instead of nested cards. Decoration obeys the north star (0.0% idle CPU with four panes): the deck is entirely static controls, and persistent animations or timers are forbidden. Expression never obscures tasks, status or familiar affordances: which pane has focus, where the path is, what's on the stash shelf, how far a task has got. All four can be scanned on one screen the moment the app opens.

Explicit anti-references: **no web-style colorful world, no nested rounded cards, no constantly redrawing showpiece motion**. QSpace is a density and feature benchmark, not an object of visual imitation. Custom-drawn identity concentrates on the everyday main view (deck/panes/stash shelf/sidebar); native components such as the search panel, settings window, system dialogs, Quick Look and context menus stay native (the **hybrid principle**).

**Key Characteristics:**
- **Zero added colors**: semantic colors + a single accent (`Theme.accent`, user-changeable), with no hardcoded brand hex anywhere.
- **Deterministic 4pt grid**: all sizes converge on a 4pt scale, mechanically enforced by `grid-lint.sh` (pre-commit).
- **Hairlines as boundaries**: 1px `separatorColor` and whitespace distance replace borders and shadows.
- **System material layering**: `NSVisualEffectView` (`.sidebar` / `.titlebar`) provides depth; the interface itself is flat.
- **Implicit semantics, direct access**: official SF Symbols + tooltips carry operations; text appears only where an icon cannot.
- **hover-reveal discipline**: zero clutter at rest, actions surface only on hover or when needed (150ms in-place feedback).

## Colors

The palette is **system semantic colors + a single dynamic accent**: there is no static brand hex, and every color resolves automatically for light and dark appearance. Both light and dark are first-class citizens (following the system).

### Primary
- **Accent** (`{colors.accent}` = `controlAccentColor`): the only brand color voice. Defaults to the system accent; users can override it in Settings from an 8-color palette (`Theme.accentPalette`: red `FF3B30` / orange `FF9500` / yellow `FFCC00` / green `28CD41` / blue `007AFF` / indigo `5E5CE6` / purple `AF52DE` / pink `FF2D55`) or fall back to the system color. Used for: active workspace tab, count pill background, active pane address bar, stash drop highlight ring, sidebar icon tint. **When the accent or appearance changes at runtime, every place that caches accent via `cgColor` must re-resolve through the `.hspaceThemeChanged` broadcast or `viewDidChangeEffectiveAppearance`** (otherwise it renders stale in dark mode, see `StashShelfView.applyAccentColors`).

### Neutral (three inks + surfaces + hairline)
- **First-level ink** (`{colors.ink-primary}` = `labelColor`): body text, active tab text, active/existing items.
- **Second-level ink** (`{colors.ink-secondary}` = `secondaryLabelColor`): default icon button tint, secondary info, inactive tabs, status bar text.
- **Third-level ink** (`{colors.ink-muted}` = `tertiaryLabelColor`): empty-state icons and copy, missing-target items, sidebar capacity subtitle.
- **Hairline** (`{colors.hairline}` = `separatorColor`): all separation (between the two deck rows, between panes, top of the status bar, vertical lines between clusters, float bar border).
- **Surfaces**: window background `windowBackgroundColor` (status bar/tab backing), control background `controlBackgroundColor` (address bar backing); the sidebar and deck are not solid colors but **system materials** (see Elevation & Depth).
- **Selected row** (`{colors.surface-selected}` = `selectedContentBackgroundColor`): selected state in list/icon/column views, using the system default highlight (no custom accent-28%; this differs from the mockup's `--surface-sel` approximation, and the code uses the system state).
- **Error red** (`{colors.error}` = `systemRed`): sidebar in-place error banner (dismisses itself after 3s, modal dialogs strictly forbidden).

### Named Rules

**The Zero-Hex Rule.** The presentation layer may not contain brand hex literals. The only allowed `NSColor(hex:)` renders the palette dots of `Theme.accentPalette` (`AppearanceSettingsPage`). Everything else is a semantic color or `Theme.accent`. Structural colors (`.black`/`.white`/`.clear`) are used only for dimming overlays, float bar shadows and transparent backgrounds, and carry no brand.

**The Accent-Alpha Rule.** The accent appears only at a fixed alpha ladder, never filling large areas: **18%** = active workspace tab background; **10%** = count pill background, status bar selection pill background, active pane address bar blend; **6%** = drag drop ring fill; **100%** = drop ring stroke, sidebar item icon tint. Scarcity and low saturation are the point: it marks state, it doesn't decorate.

## Typography

**Font family:** system font throughout (`.systemFont` / `-apple-system`, i.e. SF Pro with PingFang SC fallback), no bundled fonts. Monospaced digits use `.monospacedDigitSystemFont`.

**Character:** system-native, compact, restrained. The scale has only four regular sizes plus one monospaced-digit tier; hierarchy comes from font size and the three inks, not from stacked weights.

### Hierarchy
- **Title** (regular, 13px): sidebar item titles, deck icon SF Symbol `pointSize` (13 / `.regular`).
- **Body** (regular, 12px, configurable 11–14): file list/icon/column cells. Externalized through `Preferences.listFontSize` (`Formatters.listFontSize`); at font size ≥13 list rows are 24pt, otherwise 22pt (`FileListViewController.rowHeight(for:)`).
- **Label** (regular, 11px): deck/status bar/workspace tab text, stash empty-state copy, sidebar group headers (`.semibold` here), error banners. The most common size in the interface.
- **Caption** (regular, 10px): capacity subtitle on sidebar leaf rows (`tertiaryLabelColor`).
- **Numeric** (medium/regular, monospaced-digit): all frequently changing digits: stash count pill (12px medium), status bar count/selection pill/available capacity (11px), list size/date columns (`Formatters.listFontSize`). All go through `.monospacedDigitSystemFont`, so digits don't jitter horizontally on refresh.

### Named Rules

**The Three-Ink Rule.** Text color is chosen only among three inks: `labelColor` (present/active) → `secondaryLabelColor` (secondary/quiet) → `tertiaryLabelColor` (placeholder/missing/units). Hierarchy comes from ink and font size, not colored text. The size column is one application of this rule: value in `labelColor` + unit in `secondaryLabelColor` (`TextCellView.configureSize`), with the unit receding in gray.

**The Tabular-Where-It-Counts Rule.** Tabular digits are used for digits that change with refresh or selection: stash count pill, status bar (count / "N selected · size" pill / available capacity), and the list's size/modified/created/added date columns. All go through `.monospacedDigitSystemFont` (converged in M21; the status bar and size/date columns previously used plain `systemFont` by mistake, which has been fixed to match the mockup's `font-variant-numeric: tabular-nums`). Non-numeric text (name/kind/path) still uses regular `systemFont`.

## Layout

**Topology (immovable, part of the structure and not of the variable visual direction):** a vertical hairline running from the top of the window to the bottom splits the window into two columns. This is HSpace's skeleton.

```
┌───────────────┬────────────────────────────────────────────────────────────────┐
│ ●●●      (40) │ [Workspace 1][Workspace 2]                            [+] (40) │ workspace tab bar
│───────────────│─────────────────────────hairline───────────────────────────────│
│  Stash shelf  │ [◫] │ [◀ ▶ ⌃] │ [⊞ ≡ ▥] ──space── [⤴ ⌘ ⇅ 🗑] │ [▭▯▯▤⊞] (36)    │ icon toolbar
│  (148)        │─────────────────────────hairline───────────────────────────────│
│───hairline────│                                                                │
│ Bookmarks     │     pane matrix (each pane has its own address bar (24))       │
│ iCloud        │                                                                │
│ Locations     │─────────────────────────hairline───────────────────────────────│
│               │ 287 items · 3 selected · 42.21 GB available               (24) │ status bar
└───────────────┴────────────────────────────────────────────────────────────────┘
                ↑ the only vertical divider, full height (sidebarColumn.height == contentView.height)
```

- **Left column (full-height sidebar)**: `NSVisualEffectView(.sidebar)`, reserving 36pt at the top (traffic-light row + top gap, `stashView.top = 36`) → stash shelf area 148pt (constant height, no jump between empty and full) → hairline → source-list outline of bookmarks/iCloud/locations (row size `.small`, QSpace-style compact). Width is managed by a handwritten `NSSplitView` (min 160 / max 320 / collapsible).
- **Right column (content column)**: at the top, the custom-drawn deck `TopDeckView` = **two rows** inside `NSVisualEffectView(.titlebar)`: workspace tab bar 40pt + hairline + icon toolbar 36pt + hairline. Below the deck is the pane matrix (`PaneGridController`), with the status bar at the very bottom. **`NSToolbar` is dropped** and the entire top bar is custom-drawn (M17 decision).
- **Each pane has its own address bar**: pane = address bar 24pt (breadcrumbs ⟷ path editing) + hairline + content view + bottom status bar 24pt. There is only one layer of tabs, on the deck (the workspace tab bar).
- **Window structure**: no title bar (`titleVisibility=.hidden`, `titlebarAppearsTransparent`, `.fullSizeContentView`, `toolbar=nil`); traffic lights stay at the system default position (inline at the top of the left column). **When the sidebar is collapsed**, the tab row's leading edge yields 80pt to the traffic lights (`trafficLightInset`, collapsed state only). Blank deck areas drag the window with `performDrag`; double-click zooms according to the system `AppleActionOnDoubleClick`.

### 4pt grid scale (deterministic grid)

All new UI sizes (constraint constants / spacing / the four `NSEdgeInsets` sides) **strictly converge on the 4pt scale**. Scale values measured in use: `4 · 8 · 12 · 16 · 20 · 24 · 28 · 36 · 80 · 100 · 112 · 148`.

**Exemption rules** (`scripts/grid-lint.sh`):
1. **Multiples of 4**: on the scale, pass straight through.
2. **|value| ≤ 2**: hairlines and optical/center-of-gravity fine-tuning (such as tab stack `spacing=2`, title `centerY` constant `-1`, address bar inset `2`).
3. **Fractional values**: 0.5 hairlines.
4. **Legacy/intentional exceptions** would be registered in `scripts/grid-lint-allow.txt` (format `filename:value`, with the reason in an inline `#`). That file does not exist today: there are no registered exceptions, and anything else fails.

`grid-lint.sh` defaults to **incremental mode** (checks only the `Sources/*.swift` staged this time, with pre-commit semantics); `GRID_LINT_ALL=1` is a full audit (CI/acceptance gate). The full audit passes today with no exceptions.

### Spacing rhythm (examples)
- Icon grid: item spacing/line spacing 8, section inset 12.
- Sidebar groups: distance instead of borders, 16 between groups and 4 within a group (mockup layout semantics).
- Deck toolbar: left cluster leading 8, right cluster trailing -8, minimum gap between left and right clusters 8.

## Elevation & Depth

**Essentially flat + system material layering.** Depth comes not from drop shadows but from three things: (1) `NSVisualEffectView` vibrant materials separate levels: sidebar `.sidebar`, deck `.titlebar`, stash float bar `.menu`; (2) 1px hairlines draw boundaries; (3) low-alpha accent backgrounds mark active/selected state. The interface is flat at rest.

### Shadow Vocabulary (the one real shadow)
- **Stash hover float bar** (`StashShelfView.floatBar`): `NSShadow` with color `black @ 28%`, `blurRadius 8`, `offset (0, -1)`, paired with the `.menu` material + 1px `separatorColor` border + 8pt corner radius. This is the only structural shadow in the whole system, and it appears only briefly while the bar is floated on hover.

### Named Rules

**The Flat-At-Rest Rule.** Surfaces have no shadow at rest. Depth comes from system materials and hairlines; shadow appears only as a **state response** (stash float bar on hover). Do not add persistent drop shadows to the deck, panes, cards or buttons.

**The Material-Not-Fill Rule.** The sidebar and deck use `NSVisualEffectView` materials (`blendingMode=.behindWindow`, `state=.followsWindowActiveState`), not solid fills, so they desaturate naturally when the window deactivates, consistent with the system.

## Shapes

A shape language of **hairlines + minimal corner radii**.

- **Hairlines**: horizontal separators are always `NSBox(boxType: .separator)` (system semantic color, automatic light/dark); vertical lines between clusters are 1px wide × 20pt tall `separatorColor` layers. Width is always 1px.
- **Corner radii**: only two tiers: workspace tab capsule **5px** (`{rounded.tab}`); count pill / hover float bar / drop ring **8px** (`{rounded.pill}`).
- **System bezels**: icon buttons (`.accessoryBarAction`, `isBordered=false`, `.momentaryChange`) and segmented controls (`.separated`) use the system appearance, with no custom radius or stroke.
- **Drop highlight**: when dragging over the stash area, an accent hairline inner ring is shown (`ringView`, 1px border + 6% fill + 8pt radius, inset 4pt), giving in-place feedback without changing layout.
- **Stash stack**: up to 3 icon layers stacked with an offset (6pt per layer, newest on top), container 112×100, icon 80×80.

## Components

Constrained by official SF Symbols and semantic colors, each component's shape, color and state are recorded as measured in code.

### Icon vocabulary (SF Symbols)
- **Only original official SF Symbols**: implementations may only use `NSImage(systemSymbolName:)` (via `NSImage.officialSymbol(_:fallback:accessibility:)`). **Custom-drawn paths are strictly forbidden, as are emoji or text standing in for icons.** When the system lacks a symbol, use the fallback in parentheses.
- Deck icons `pointSize 13 / .regular`; stash float bar `12 / .medium`; sidebar eject `10`; count arrow `8`; tab close `7`.
- **Final symbol table (M17 §6.1, authoritative):**

| Action | Official symbol (fallback) |
|---|---|
| Back / Forward / Up | `chevron.backward` / `chevron.forward` / `arrow.up` |
| View type (3 segments) | `square.grid.2x2` / `list.bullet` / `rectangle.split.3x1` |
| AirDrop | `airdrop` (fallback `dot.radiowaves.left.and.right`) |
| Open in Terminal | `apple.terminal` (fallback `terminal`) |
| File operation tasks | `arrow.up.arrow.down` (two-way transfer arrows; the circular arrow was dropped to remove the "refresh" misreading) |
| Layout (5 segments, same family) | `rectangle` / `rectangle.split.2x1` / `rectangle.split.1x2` / `rectangle.split.3x1` / `rectangle.split.2x2` |
| Sidebar toggle | `sidebar.leading` (fallback `sidebar.left`) |
| Stash shelf five buttons | `doc.on.doc` / `arrow.forward.square` / `airdrop` / `trash` / `ellipsis.circle` |
| Stash empty state | `tray.and.arrow.down` |
| Sidebar items | `folder.fill` / `icloud` / `internaldrive` + accent tint |

### Icon toolbar (second deck row)
- **A1 left/right split**: `[sidebar toggle] │ [◀ ▶ ⌃] │ [view 3 segments] ── flexible space (doubles as window drag handle) ── [AirDrop Terminal Tasks Trash] │ [layout 5 segments]`. Left = high-frequency navigation/view (close to the content), right = global actions/layout.
- **Buttons**: `icon-button` 24×24, `contentTintColor = secondaryLabelColor`, SF13. ⚠️ **Cluster gap as measured**: not a literal 16pt, but `NSStackView spacing=8` + a 1px×20pt hairline vertical, visually ≈16pt; the four action buttons in the right cluster use `spacing=4` internally.
- **Segmented controls**: navigation `.separated`/`.momentary` (segment width 26, long-press on back/forward segments pops the history menu after 0.4s); view `.selectOne` (segment width 28); layout `.separated`/`.selectOne` (segment width 28, segment count = `PaneLayout.allCases`).
- **Action validation (FG-1, no fake buttons)**: AirDrop/Trash are enabled only with a selection; Terminal/Tasks are always available. Responder-chain actions use `target=nil` to bubble up to the active pane.

### Workspace tabs (`TabBarView` / `TabItemView`)
- **Capsule**: 5px radius, 28pt tall in the deck (`itemHeight`; 20pt is the `TabBarView` default), 160pt max width. **Active** = `Theme.accent @ 18%` background + `labelColor` text; **inactive** = transparent background + `secondaryLabelColor`. Font size 11.
- **hover-reveal close button** (`xmark`, SF7): hidden at rest, shown only on mouse enter (and only when closable, `titles.count > 1`); middle-click closes directly.
- When reused inside the deck, `useTransparentBackground()` lets the `.titlebar` material show through; the trailing `+` creates a new one.

### Count pill (stash shelf, `count-pill`)
- 8px radius, 16pt tall, `Theme.accent @ 10%` background, `labelColor` text (⚠️ not accent-colored text, unlike the mockup), font 12pt monospaced-digit medium, trailing `chevron.down` (SF8).
- Content: the file name for one item, the count for several. Click = per-item management menu (remove/clear).

### Stash shelf (`StashShelfView`, signature component · B2 hover-reveal)
- **At rest**: within the 148pt area only the stack + count pill are visible, centered as a group (`|center offset| ≤ 2pt`, I-07 regression). The stack has 3 offset layers.
- **After 150ms of hover**: the action bar `floatBar` floats up from the bottom (`.menu` material + hairline border + shadow, five 20×20 buttons at spacing 4: copy/move/AirDrop/clear/more). **The float bar is an overlay (positioned by `frame`, not in the main Auto Layout chain, no layout change; FG-4 spatial stability)**; it hides on mouse exit.
- **Drag hover**: hides the float bar and shows the accent hairline inner ring as a drop highlight (in-place feedback).
- **Empty state**: `tray.and.arrow.down` (`tertiaryLabelColor`) + "Drop files here to stash" in 11pt muted copy.

### Pane address bar (`PaneViewController` / `AddressBarBacking`, `pane-address-active`)
- 24pt tall, switching between breadcrumbs ⟷ path editor. The backing uses `updateLayer` (appearance-aware, re-resolved automatically on light/dark and theme broadcasts).
- **Active pane highlight**: ⚠️ as measured, the **entire backing** is `controlBackgroundColor` blended with **10% accent** (`blended(withFraction:0.10)`), controlled by the `Preferences.activePaneHighlight` switch. It is **not** the mockup's "2px accent bottom glow". Inactive panes can optionally dim their content (`inactivePaneDimming`, 0~0.3, default 0).

### File list / icons / columns
- List row height 22pt (font size <13) or 24pt (≥13); `usesAlternatingRowBackgroundColors` (system zebra); selection uses the system `selectedContentBackgroundColor`. Cell font `Formatters.listFontSize` (default 12), text `labelColor`/secondary `secondaryLabelColor`.
- Icon grid: item spacing/line spacing 8, section inset 12, `itemSize = icon edge + 32`.

### Status bar (`StatusBarView`, `status-bar`)
- 24pt tall, `windowBackgroundColor` backing + top hairline, two 11pt `secondaryLabelColor` labels: left "N items (M selected)", right "X GB available". ⚠️ No pills, no tabular-nums (unlike the mockup). Capacity is read only once on directory change or tab switch (`statfs`-level read-only), never polled, per the north star of zero idle power.

### Sidebar (`SidebarViewController` / `SidebarLeafCell`)
- source-list outline, row size `.small`; group headers 11pt `.semibold` `secondaryLabelColor`.
- Leaf rows: 16×16 icon (accent tint, Finder-blue style) + 13pt title + optional 10pt `tertiaryLabelColor` capacity subtitle + eject button (`eject.fill`, SF10, shown only for ejectable volumes). Missing targets are grayed to `tertiaryLabelColor`.
- Errors use an in-place banner (dismisses after 3s), never a modal.

## Do's and Don'ts

Notes for contributors adding UI. **Any new UI must pass both `grid-lint` and the principles below.**

### Do:
- **Do** use only macOS semantic colors (the `labelColor` family / `separatorColor` / `windowBackgroundColor` / `controlBackgroundColor`) and `Theme.accent`; colors resolve dynamically for light and dark.
- **Do** converge all sizes on the 4pt scale; keep hairline/optical fine-tuning at |value|≤2 or the 0.5 fraction; before committing, run `GRID_LINT_ALL=1 ./scripts/grid-lint.sh` and get exit 0.
- **Do** use only official SF Symbols for icons, obtained through `NSImage.officialSymbol(...)` with fallback + accessibility; give every icon a tooltip.
- **Do** draw boundaries with hairlines (`NSBox .separator`) and whitespace distance; leave depth to `NSVisualEffectView` materials.
- **Do** use accent only at the alpha ladder (18% / 10% / 6% / 100%), to mark state rather than decorate.
- **Do** make actions hover-reveal with 150ms in-place feedback, and position overlays by `frame` without changing the main chain layout (FG-4 spatial stability).
- **Do** listen for `.hspaceThemeChanged` and override `viewDidChangeEffectiveAppearance` to re-resolve when caching accent `cgColor`.
- **Do** wire every new button to a real action + `validate` (FG-1 no fake buttons); put new configurable items in `Preferences` (externalized); route shortcuts through the `KeyBindings` registry.

### Don't:
- **Don't** hardcode brand hex or flashy web color schemes; apart from rendering `Theme.accentPalette` dots, the presentation layer may not contain `NSColor(hex:)`/`srgbRed:` literals.
- **Don't** use non-4pt sizes without registering them in `grid-lint-allow.txt`. **Files in M17 scope may not add new entries.**
- **Don't** custom-draw icon paths, use emoji or text as icons, or place icons first and add the function later.
- **Don't** add persistent shadows, borders or nested rounded cards to surfaces at rest; the only structural shadow is the stash hover float bar.
- **Don't** introduce persistent animations, timers or polling (north star: 0.0% idle CPU with four panes).
- **Don't** touch components that already work well natively (global search/settings window/system dialogs/Quick Look/context menus); the hybrid principle only redoes the top structure of the main view.
- **Don't** fill large areas with accent or use colored text to build hierarchy; hierarchy comes from the three inks + font size.
- **Don't** bypass pre-commit with `--no-verify` (pod-lint / grid-lint / tests).
