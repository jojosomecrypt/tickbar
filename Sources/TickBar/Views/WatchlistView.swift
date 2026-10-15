import SwiftUI

struct WatchlistView: View {
    @Environment(Store.self) private var store
    @State private var expanded: String?

    init(expanded: String? = nil) { _expanded = State(initialValue: expanded) }

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            HStack {
                Picker("Change", selection: $store.config.changeWindow) {
                    ForEach(ChangeWindow.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Spacer()
                Picker("Sort", selection: $store.config.sort) {
                    ForEach(SortMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden().fixedSize()
            }
            .padding(.horizontal, 12).padding(.vertical, 8)

            if store.config.watchlist.isEmpty {
                ContentUnavailableView("No coins yet", systemImage: "chart.line.uptrend.xyaxis",
                                       description: Text("Add some from the Add coins tab."))
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(store.sortedWatchlist) { item in
                            WatchRow(item: item, expanded: $expanded)
                                .if(store.config.sort == .custom) { row in
                                    row.draggable(item.id)
                                        .dropDestination(for: String.self) { ids, _ in
                                            guard let id = ids.first else { return false }
                                            withAnimation(.easeOut(duration: 0.15)) { store.move(id, before: item.id) }
                                            return true
                                        }
                                }
                            Divider().padding(.leading, 12)
                        }
                    }
                }
            }

            Text(store.config.sort == .custom
                 ? "☑ menu bar · drag ≡ to reorder · click for details · ⌘-click for chart"
                 : "☑ menu bar · click for details · ⌘-click for chart")
                .font(.system(size: 10.5)).foregroundStyle(.tertiary)
                .padding(.vertical, 6)
        }
    }
}

struct WatchRow: View {
    @Environment(Store.self) private var store
    let item: WatchItem
    @Binding var expanded: String?
    @State private var hovering = false
    private var isOpen: Bool { expanded == item.id }

    var body: some View {
        let chg = store.change(item)
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if store.config.sort == .custom {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(hovering ? .secondary : .quaternary)
                        .frame(width: 12)
                        .padding(.trailing, -4)
                        .onHover { inside in inside ? NSCursor.openHand.push() : NSCursor.pop() }
                        .help("Drag to reorder")
                }
                Toggle("", isOn: Binding(get: { item.inMenuBar },
                                         set: { v in store.edit(item.id) { $0.inMenuBar = v } }))
                    .toggleStyle(.checkbox).labelsHidden()
                    .help("Show in menu bar")

                HStack(spacing: 9) {
                    CoinLogo(base: item.base, item: item, size: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 5) {
                            Text(item.base).font(.system(size: 13, weight: .semibold))
                            if item.market != .spot { MarketBadge(market: item.market) }
                        }
                        Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if store.config.showSparklines {
                        Sparkline(values: store.sparkline(item)).frame(width: 60, height: 22)
                    }
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(store.priceText(item)).font(.system(size: 13, weight: .medium).monospacedDigit())
                        Text(Fmt.pct(chg, digits: 2)).font(.system(size: 11).monospacedDigit()).foregroundStyle(changeColor(chg))
                    }
                    .frame(minWidth: 84, alignment: .trailing)
                }

                Image(systemName: "chevron.down").rotationEffect(.degrees(isOpen ? 180 : 0))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .contentShape(Rectangle())
            // Click anywhere on the row for details; ⌘-click jumps straight to the chart.
            .onTapGesture {
                if NSEvent.modifierFlags.contains(.command) {
                    NSWorkspace.shared.open(store.chartURL(item))
                } else {
                    withAnimation(.easeOut(duration: 0.15)) { expanded = isOpen ? nil : item.id }
                }
            }
            .help("Click for details · ⌘-click to open the chart")

            if isOpen {
                RowDetail(item: item)
                    .padding(.horizontal, 12).padding(.bottom, 10)
            }
        }
        .background(isOpen ? Color.primary.opacity(0.04) : hovering ? Color.primary.opacity(0.025) : .clear)
        .onHover { hovering = $0 }
        .contextMenu {
            if store.config.sort == .custom {
                Button("Move up") { withAnimation(.easeOut(duration: 0.15)) { store.move(item.id, by: -1) } }
                    .disabled(store.config.watchlist.first?.id == item.id)
                Button("Move down") { withAnimation(.easeOut(duration: 0.15)) { store.move(item.id, by: 1) } }
                    .disabled(store.config.watchlist.last?.id == item.id)
                Divider()
            }
            if item.market == .dex {
                Button("Open on DexScreener") { NSWorkspace.shared.open(store.chartURL(item)) }
            } else {
                Button("Open on Binance") { NSWorkspace.shared.open(store.chartURL(item, site: .binance)) }
                Button("Open on TradingView") { NSWorkspace.shared.open(store.chartURL(item, site: .tradingview)) }
            }
            Divider()
            Button(item.inMenuBar ? "Hide from menu bar" : "Show in menu bar") {
                store.edit(item.id) { $0.inMenuBar.toggle() }
            }
            Button("Remove from watchlist", role: .destructive) { store.remove(item.id) }
        }
    }

    private var subtitle: String {
        if !store.isListed(item) { return "Not listed on Binance \(item.market.label.lowercased())" }
        let name = store.displayName(item)
        if let v = store.holdingsValue(item) {
            return "\(Fmt.qty(item.holdings)) = \(Fmt.money(v, store.currency))"
        }
        return name.isEmpty ? store.instrument(for: item).symbol : name
    }
}

struct RowDetail: View {
    @Environment(Store.self) private var store
    let item: WatchItem

    var body: some View {
        let inst = store.instrument(for: item)
        let t = store.ticker(item)
        let fx = store.fxRate
        let cur = store.currency
        VStack(alignment: .leading, spacing: 10) {
            if item.market == .dex {
                dexStats(t)
            } else {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                GridRow {
                    stat("Pair", inst.symbol)
                    stat("24h high", t.map { Fmt.price($0.high * fx, cur) } ?? "–")
                    stat("24h low", t.map { Fmt.price($0.low * fx, cur) } ?? "–")
                }
                GridRow {
                    stat("24h vol", t.map { cur.symbol + Fmt.short($0.quoteVolume * fx) } ?? "–")
                    stat("1h", Fmt.pct(store.change(item, window: .h1), digits: 2))
                    stat("Today", Fmt.pct(store.change(item, window: .today), digits: 2))
                }
                if inst.market == .perp, let p = store.perp[inst.key] {
                    GridRow {
                        stat("Mark", Fmt.price(p.mark * fx, cur))
                        stat("Funding", Fmt.pct(p.funding, digits: 4))
                        stat("Next funding", Fmt.countdown(to: p.nextFunding, now: store.clock))
                    }
                }
            }
            }
            if let t {
                Text("Last tick \(Fmt.ago(t.updated, now: store.clock))").font(.system(size: 10.5)).foregroundStyle(.tertiary)
            }

            HStack(spacing: 6) {
                Text("Holdings").frame(width: 62, alignment: .leading)
                TextField("0", value: Binding(get: { item.holdings },
                                              set: { v in store.edit(item.id) { $0.holdings = max(0, v) } }),
                          format: .number)
                    .textFieldStyle(.roundedBorder).frame(width: 120)
                Text(item.base).foregroundStyle(.secondary)
                Spacer()
                if let v = store.holdingsValue(item) { Text(Fmt.money(v, cur)).monospacedDigit() }
            }

            HStack(spacing: 6) {
                Text("Decimals").frame(width: 62, alignment: .leading)
                Picker("", selection: Binding(get: { item.decimals ?? -1 },
                                              set: { v in store.edit(item.id) { $0.decimals = v < 0 ? nil : v } })) {
                    Text("Auto").tag(-1)
                    ForEach(0...8, id: \.self) { Text("\($0)").tag($0) }
                }
                .labelsHidden().fixedSize()
                if let t {
                    Text(Fmt.price(t.price * fx, cur, decimals: item.decimals)).foregroundStyle(.secondary).monospacedDigit()
                }
            }

            Text("Alerts").font(.system(size: 11.5, weight: .semibold))
            AlertForm(fixedItemID: item.id)
            ForEach(store.config.alerts.filter { $0.itemID == item.id }) { a in
                AlertLine(alert: a, compact: true)
            }

            HStack {
                if item.market == .dex {
                    Button("DexScreener") { NSWorkspace.shared.open(store.chartURL(item)) }
                } else {
                    Button("Binance") { NSWorkspace.shared.open(store.chartURL(item, site: .binance)) }
                    Button("TradingView") { NSWorkspace.shared.open(store.chartURL(item, site: .tradingview)) }
                }
                Spacer()
                Button("Remove", role: .destructive) { store.remove(item.id) }
            }
            .controlSize(.small)
        }
        .font(.system(size: 11.5))
    }

    @ViewBuilder private func dexStats(_ t: Ticker?) -> some View {
        let fx = store.fxRate, cur = store.currency
        let p = store.dexInfo[store.instrument(for: item).key]
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
            GridRow {
                stat("Pool", "\(item.base)/\(item.quoteSymbol ?? "?")")
                stat("Exchange", "\(item.dexName ?? "?") · \(item.chain ?? "?")")
                stat("Liquidity", p.map { cur.symbol + Fmt.short($0.liquidity * fx) } ?? "–")
            }
            GridRow {
                stat("24h vol", t.map { cur.symbol + Fmt.short($0.quoteVolume * fx) } ?? "–")
                stat("1h", Fmt.pct(store.change(item, window: .h1), digits: 2))
                stat("24h", Fmt.pct(store.change(item, window: .h24), digits: 2))
            }
        }
        Text("DEX price via DexScreener, refreshed every ~6s").font(.system(size: 10.5)).foregroundStyle(.tertiary)
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(value).monospacedDigit()
        }
    }
}
