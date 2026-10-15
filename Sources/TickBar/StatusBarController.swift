import AppKit
import SwiftUI

/// Owns the NSStatusItem. AppKit (not MenuBarExtra) because the menu bar title
/// needs per-coin colors, logo attachments and tick flashes.
@MainActor
final class StatusBarController: NSObject, NSWindowDelegate {
    private let store: Store
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let panel: DropdownPanel
    private var clickMonitor: Any?
    private var lastHide = Date.distantPast
    private var timer: Timer?
    private var rotateIndex = 0
    private var lastRotate = Date()
    private(set) var lastTitle: NSAttributedString?

    init(store: Store) {
        self.store = store
        panel = DropdownPanel(content: PopoverView().environment(store), size: NSSize(width: 440, height: 580))
        super.init()
        panel.delegate = self
        item.button?.target = self
        item.button?.action = #selector(toggle)
        item.button?.imagePosition = .imageLeft
        render()
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.render() }
        }
    }

    // A self-positioned panel instead of NSPopover: NSPopover re-anchors every time the
    // status item's title changes (several times a second here) and sometimes lands
    // under the menu bar. The panel's frame is set once per open and never moves.
    @objc private func toggle() {
        if panel.isVisible {
            hide()
        } else if Date().timeIntervalSince(lastHide) > 0.25 { // click on the icon that just closed it
            show()
        }
    }

    private func show() {
        guard let barWindow = item.button?.window, let screen = barWindow.screen ?? NSScreen.main else { return }
        let anchor = barWindow.frame
        let size = panel.frame.size
        let visible = screen.visibleFrame
        let x = min(max(anchor.midX - size.width / 2, visible.minX + 8), visible.maxX - size.width - 8)
        let y = min(anchor.minY, visible.maxY) - size.height - 4
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        item.button?.highlight(true)
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
    }

    private func hide() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        item.button?.highlight(false)
        lastHide = Date()
        if let m = clickMonitor { NSEvent.removeMonitor(m) }
        clickMonitor = nil
    }

    func windowDidResignKey(_ notification: Notification) { hide() }

    private var font: NSFont {
        let size = NSFont.systemFontSize
        return store.config.barFont == .mono
            ? .monospacedSystemFont(ofSize: size, weight: .regular)
            : .monospacedDigitSystemFont(ofSize: size, weight: .regular)
    }

    private func visibleItems() -> [WatchItem] {
        let c = store.config
        let all = c.watchlist.filter(\.inMenuBar)
        guard c.rotate, c.rotateCount > 0, all.count > c.rotateCount else { return all }
        if Date().timeIntervalSince(lastRotate) >= Double(max(1, c.rotateSeconds)) {
            lastRotate = Date()
            rotateIndex = (rotateIndex + c.rotateCount) % all.count
        }
        rotateIndex %= all.count
        return (0..<c.rotateCount).map { all[(rotateIndex + $0) % all.count] }
    }

    func render() {
        let c = store.config
        let now = Date()
        let s = NSMutableAttributedString()
        let base: [NSAttributedString.Key: Any] = [.font: font, .baselineOffset: 0]
        let stale: Bool
        if case .stale = store.health { stale = true } else { stale = false }

        func add(_ text: String, _ color: NSColor = .labelColor, flash: NSColor? = nil) {
            var a = base
            a[.foregroundColor] = stale ? NSColor.secondaryLabelColor : color
            if let flash { a[.backgroundColor] = flash.withAlphaComponent(0.28) }
            s.append(NSAttributedString(string: text, attributes: a))
        }

        if stale { add("⚠︎ ", .systemOrange) }

        var pieces = 0
        if c.barShowPortfolio, let v = store.portfolioValue {
            add("Σ " + (c.barCompact ? store.currency.symbol + Fmt.short(v) : Fmt.money(v, store.currency)))
            pieces += 1
        }

        let items = visibleItems()
        for item in items {
            if pieces > 0 { add("  ·  ", .tertiaryLabelColor) }
            pieces += 1
            let inst = store.instrument(for: item)
            let t = store.tickers[inst.key]
            let chg = store.change(item)

            var color = NSColor.labelColor
            switch c.colorMode {
            case .change: if let chg { color = chg >= 0 ? .systemGreen : .systemRed }
            case .tick: if let d = t?.tickDir, d != 0 { color = d > 0 ? .systemGreen : .systemRed }
            case .none: break
            }
            var flash: NSColor?
            if c.flashOnTick, let f = store.flashes[inst.key], f.until > now {
                flash = f.dir > 0 ? .systemGreen : .systemRed
            }

            if c.barShowLogo, let img = store.logo(for: item) {
                let att = NSTextAttachment()
                att.image = img
                att.bounds = CGRect(x: 0, y: -3, width: 14, height: 14)
                s.append(NSAttributedString(attachment: att))
                add(" ")
            }
            if c.barShowSymbol {
                add(item.base)
                if item.market == .perp { add("ᴾ", .secondaryLabelColor) }
                if c.barShowPrice || c.barShowChange { add(" ") }
            }
            if c.barShowPrice {
                add(store.priceText(item, compact: c.barCompact), color, flash: flash)
            }
            if c.barShowChange {
                add((c.barShowPrice ? " " : "") + Fmt.pct(chg), color, flash: c.barShowPrice ? nil : flash)
            }
        }
        if pieces == 0 { add("TickBar") }

        if lastTitle != s {
            lastTitle = s
            item.button?.attributedTitle = s
        }
        item.button?.toolTip = tooltip()
    }

    private func tooltip() -> String {
        switch store.health {
        case .live: return "TickBar · live from Binance"
        case .connecting: return "TickBar · connecting to Binance…"
        case .lagging(let s): return "TickBar · last update \(s)s ago"
        case .stale(let s): return "TickBar · no data for \(s)s, reconnecting. Prices shown may be old."
        }
    }
}

/// Borderless floating panel styled like a popover (rounded, translucent material).
final class DropdownPanel: NSPanel {
    init<V: View>(content: V, size: NSSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .statusBar // below .popUpMenu so Picker menus open on top of the panel
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        effect.material = .popover
        effect.state = .active
        effect.blendingMode = .behindWindow
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 10
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 0.5
        effect.layer?.borderColor = NSColor.separatorColor.cgColor

        let host = NSHostingView(rootView: content)
        host.frame = effect.bounds
        host.autoresizingMask = [.width, .height]
        effect.addSubview(host)
        contentView = effect
    }

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) { // Esc closes
        resignKey()
        orderOut(nil)
    }
}
