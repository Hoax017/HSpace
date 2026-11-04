import AppKit

/// Settings search index: built by **walking the real assembled view tree**, with no per-page registration.
///
/// Why the view tree rather than a hand-written (title key, tab) table: a hand-written table drifts from the pages:
/// add an item, forget to register it, and search misses it with nothing flagging the gap.
/// Working back from the rendered controls keeps the index identical to the UI.
@MainActor
enum SettingsSearch {

    /// One searchable, navigable settings item
    struct Hit {
        /// Display text (the control's own title/label)
        let text: String
        /// Owning tab index (for jumping)
        let tabIndex: Int
        /// Owning tab title (shows "which page" in the results)
        let tabLabel: String
        /// The real control (scrolled to and flashed after a jump)
        let view: NSView
    }

    /// Builds the full index from an assembled NSTabView
    static func index(_ tabs: NSTabView) -> [Hit] {
        var out: [Hit] = []
        for (i, item) in tabs.tabViewItems.enumerated() {
            guard let root = item.view else { continue }
            for (text, v) in labelled(in: root) {
                out.append(Hit(text: text, tabIndex: i, tabLabel: item.label, view: v))
            }
        }
        return out
    }

    /// Recursively collects "controls with visible text". Deliberately limited to these kinds:
    /// collecting every NSView would pull in separators, containers and empty labels, and the results would be all noise.
    private static func labelled(in root: NSView) -> [(String, NSView)] {
        var out: [(String, NSView)] = []
        func walk(_ v: NSView) {
            switch v {
            case let b as NSButton:
                // Title of a checkbox/radio/plain button
                let t = b.title.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { out.append((t, b)) }
            case let f as NSTextField:
                // Static labels only (editable ones are input fields, whose value is not a "setting name")
                if !f.isEditable {
                    let t = f.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty { out.append((t, f)) }
                }
            case let p as NSPopUpButton:
                // When a popup has no title of its own, use its options as extra searchable text ("List/Icons/Columns" and the like)
                let opts = p.itemTitles.joined(separator: " ")
                if !opts.isEmpty { out.append((opts, p)) }
            default:
                break
            }
            for sub in v.subviews { walk(sub) }
        }
        walk(root)
        return out
    }

    /// Matching: case- and diacritic-insensitive substring. Priority: prefix hits rank before mid-string hits.
    static func matches(_ query: String, in hits: [Hit], limit: Int = 12) -> [Hit] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        var prefix: [Hit] = []
        var contains: [Hit] = []
        for h in hits {
            let combined = h.text + " " + h.tabLabel
            guard combined.localizedCaseInsensitiveContains(q) else { continue }
            if h.text.lowercased().hasPrefix(q.lowercased()) { prefix.append(h) } else { contains.append(h) }
        }
        return Array((prefix + contains).prefix(limit))
    }

    /// Jump to an item: switch page -> scroll into view -> flash a highlight.
    /// The flash is necessary: on a page with a dozen items, merely "arriving at the page" does not show which item it is.
    static func reveal(_ hit: Hit, in tabs: NSTabView) {
        tabs.selectTabViewItem(at: hit.tabIndex)
        hit.view.scrollToVisible(hit.view.bounds.insetBy(dx: -8, dy: -8))
        flash(hit.view)
    }

    /// Flash an accent-colored ring around the control (gone by itself after 1.2s, leaves no residual layer)
    static func flash(_ view: NSView) {
        view.wantsLayer = true
        guard let layer = view.layer else { return }
        let ring = CALayer()
        ring.frame = view.bounds.insetBy(dx: -3, dy: -3)
        ring.cornerRadius = 4
        ring.borderWidth = 2
        ring.borderColor = Theme.accent.cgColor
        ring.opacity = 0
        layer.addSublayer(ring)
        let anim = CAKeyframeAnimation(keyPath: "opacity")
        anim.values = [0, 1, 1, 0]
        anim.keyTimes = [0, 0.15, 0.75, 1]
        anim.duration = 1.2
        ring.add(anim, forKey: "flash")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.25) { ring.removeFromSuperlayer() }
    }
}
