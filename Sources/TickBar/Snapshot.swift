import AppKit
import SwiftUI

/// Dev aid: TICKBAR_SNAPSHOT=/some/dir renders the menu bar title and every
/// dropdown tab to PNGs after the feed has warmed up, then quits.
@MainActor
enum Snapshot {
    private static var windows: [(Tab, NSWindow, NSView)] = []

    static func run(store: Store, bar: StatusBarController, dir: String) {
        let out = URL(fileURLWithPath: dir)
        let appearance = NSAppearance(named: .darkAqua)
        NSApp.appearance = appearance
        if let cfg = ProcessInfo.processInfo.environment["TICKBAR_CONFIG"], let data = cfg.data(using: .utf8),
           let c = try? JSONDecoder().decode(Config.self, from: data) {
            store.config = c
        }
        let expand = ProcessInfo.processInfo.environment["TICKBAR_EXPAND"]
        if let addr = ProcessInfo.processInfo.environment["TICKBAR_DEX_ADD"] {
            Task {
                let found = (try? await DexAPI.lookup(address: addr)) ?? []
                print("DEX LOOKUP:", found.map { "\($0.baseSymbol) \($0.dex)/\($0.chain) $\($0.price) vol \(Int($0.volume24))" })
                if let p = found.first { store.addDex(p); store.edit(store.dexItem(p).id) { $0.inMenuBar = true } }
            }
        }

        // Mount the views early so their async work (logos, snapshots) can run, capture later.
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            store.notificationsAllowed = nil // dev builds have no bundle id; keep the banner out of shots
            for tab in Tab.allCases {
                let view = NSHostingView(rootView: PopoverView(tab: tab, expanded: expand).environment(store)
                    .background(Color(nsColor: NSColor(white: 0.17, alpha: 1))).preferredColorScheme(.dark))
                view.frame = NSRect(x: 0, y: 0, width: 440, height: 580)
                let win = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                win.appearance = appearance
                win.contentView = view
                windows.append((tab, win, view))
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 14) {
            bar.render()
            if let title = bar.lastTitle {
                let size = title.size()
                let img = NSImage(size: NSSize(width: size.width + 24, height: 24))
                img.lockFocus()
                NSColor(white: 0.16, alpha: 1).setFill()
                NSRect(origin: .zero, size: img.size).fill()
                appearance?.performAsCurrentDrawingAppearance { title.draw(at: NSPoint(x: 12, y: 3)) }
                img.unlockFocus()
                if let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                    try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent("bar.png"))
                }
                print("BAR:", title.string)
            }
            for (tab, _, view) in windows {
                view.layoutSubtreeIfNeeded()
                if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent("tab-\(tab).png"))
                }
            }
            print("SERIES:", store.config.watchlist.map { "\($0.base) \(store.sparkline($0).count)pts" })
            print("HEALTH:", store.health, "TICKERS:", store.tickers.count, "CATALOG:", store.catalogCount, "LOGOS:", store.logos.count)
            NSApp.terminate(nil)
        }
    }
}
