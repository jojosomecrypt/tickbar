import SwiftUI

struct PickerView: View {
    enum MarketFilter: String, CaseIterable { case all = "All", spot = "Spot", perp = "Perps", dex = "DEX" }
    enum DexState { case idle, loading, done, failed }

    @Environment(Store.self) private var store
    @State private var query = ""
    @State private var selectedOnly = false
    @State private var market: MarketFilter = .all
    @State private var dexResults: [DexAPI.Pair] = []
    @State private var dexState: DexState = .idle

    private var rows: [WatchItem] {
        let q = query.trimmingCharacters(in: .whitespaces).uppercased()
        let items = store.catalogItems().filter { item in
            if market == .spot && item.market != .spot { return false }
            if market == .perp && item.market != .perp { return false }
            if selectedOnly && !store.isWatched(item.market, item.base) { return false }
            if q.isEmpty { return true }
            return item.base.contains(q) || store.name(item.base).uppercased().contains(q)
        }
        func rank(_ i: WatchItem) -> Int {
            if q.isEmpty { return 0 }
            if i.base == q { return 0 }
            if i.base.hasPrefix(q) { return 1 }
            return 2
        }
        return items.sorted { a, b in
            let ra = rank(a), rb = rank(b)
            if ra != rb { return ra < rb }
            let va = store.ticker(a)?.quoteVolume ?? 0, vb = store.ticker(b)?.quoteVolume ?? 0
            if va != vb { return va > vb }
            return a.id < b.id
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                HStack {
                    HStack(spacing: 5) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField(market == .dex ? "Token name or contract address"
                              : "Search \(store.catalogCount > 0 ? "\(store.catalogItems().count) " : "")Binance markets, or paste a contract",
                              text: $query)
                            .textFieldStyle(.plain)
                        if !query.isEmpty {
                            Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                                .buttonStyle(.borderless)
                        }
                    }
                    .padding(.horizontal, 7).padding(.vertical, 5)
                    .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                    Toggle("Selected only", isOn: $selectedOnly).toggleStyle(.checkbox)
                }
                Picker("", selection: $market) {
                    ForEach(MarketFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
            }
            .padding(.horizontal, 12).padding(.top, 10)

            if store.catalogCount == 0 && market != .dex {
                Spacer()
                ProgressView("Loading Binance markets…").controlSize(.small)
                Spacer()
            } else {
                List {
                    if showDexSection { dexSection }
                    if market != .dex {
                        Section(showDexSection ? "Binance" : "") {
                            ForEach(rows) { PickerRow(item: $0) }
                        }
                    }
                }
                .listStyle(.plain)
                .task(id: query) {
                    dexResults = []
                    dexState = .idle
                    // Contract addresses look up instantly; names wait for an explicit search (or the DEX tab).
                    guard DexAPI.isAddress(query) || (market == .dex && query.count >= 2) else { return }
                    try? await Task.sleep(for: .milliseconds(400))
                    if !Task.isCancelled { await runDexSearch() }
                }
                .task {
                    while !Task.isCancelled {
                        await store.snapshotAll()
                        try? await Task.sleep(for: .seconds(60))
                    }
                }
            }
        }
    }
}

extension PickerView {
    private var showDexSection: Bool {
        market == .dex || (market == .all && !query.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    @ViewBuilder private var dexSection: some View {
        Section("DEX tokens · via DexScreener") {
            let q = query.trimmingCharacters(in: .whitespaces)
            switch dexState {
            case .idle:
                if q.isEmpty {
                    Text("Paste a contract address (any chain), or type a token name.")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                } else {
                    Button { Task { await runDexSearch() } } label: {
                        Label("Search DEXs for “\(q)”", systemImage: "magnifyingglass")
                    }
                    .buttonStyle(.borderless)
                }
            case .loading:
                HStack { ProgressView().controlSize(.small); Text("Searching DexScreener…").foregroundStyle(.secondary) }
            case .failed:
                Text("Couldn't reach DexScreener. Try again in a moment.").font(.system(size: 11.5)).foregroundStyle(.secondary)
            case .done where dexResults.isEmpty:
                Text("No DEX pools found for “\(q)”.").font(.system(size: 11.5)).foregroundStyle(.secondary)
            case .done:
                ForEach(dexResults, id: \.pair) { DexResultRow(pair: $0) }
            }
        }
    }

    private func runDexSearch() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        dexState = .loading
        let r = DexAPI.isAddress(q) ? try? await DexAPI.lookup(address: q) : try? await DexAPI.search(q)
        guard q == query.trimmingCharacters(in: .whitespaces) else { return }
        dexResults = r ?? []
        dexState = r == nil ? .failed : .done
    }
}

struct DexResultRow: View {
    @Environment(Store.self) private var store
    let pair: DexAPI.Pair

    var body: some View {
        let item = store.dexItem(pair)
        let watched = store.isWatched(item.id)
        HStack(spacing: 9) {
            Toggle("", isOn: Binding(get: { watched }, set: { _ in watched ? store.remove(item.id) : store.addDex(pair) }))
                .toggleStyle(.checkbox).labelsHidden()
            AsyncImage(url: pair.image.flatMap(URL.init(string:))) { img in
                img.resizable()
            } placeholder: {
                Circle().fill(.quaternary)
            }
            .frame(width: 18, height: 18).clipShape(Circle())
            VStack(alignment: .leading, spacing: 0) {
                Text(pair.baseSymbol).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                Text("\(pair.baseName) · \(pair.dex) on \(pair.chain) · liq \(store.currency.symbol)\(Fmt.short(pair.liquidity * store.fxRate))")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            MarketBadge(market: .dex)
            VStack(alignment: .trailing, spacing: 0) {
                Text(Fmt.price(pair.price * store.fxRate, store.currency)).font(.system(size: 12).monospacedDigit())
                Text(Fmt.pct(pair.change24h)).font(.system(size: 10.5).monospacedDigit()).foregroundStyle(changeColor(pair.change24h))
            }
            .frame(width: 84, alignment: .trailing)
        }
        .contentShape(Rectangle())
        .onTapGesture { watched ? store.remove(item.id) : store.addDex(pair) }
    }
}

struct PickerRow: View {
    @Environment(Store.self) private var store
    let item: WatchItem

    var body: some View {
        let watched = store.isWatched(item.market, item.base)
        let chg = store.change(item, window: .h24)
        HStack(spacing: 9) {
            Toggle("", isOn: Binding(get: { watched }, set: { _ in store.toggleWatch(item.market, item.base) }))
                .toggleStyle(.checkbox).labelsHidden()
            CoinLogo(base: item.base, size: 18)
            Text(item.base).font(.system(size: 12.5, weight: .semibold)).frame(width: 78, alignment: .leading).lineLimit(1)
            Text(store.name(item.base)).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 4)
            MarketBadge(market: item.market)
            VStack(alignment: .trailing, spacing: 0) {
                Text(store.priceText(item)).font(.system(size: 12).monospacedDigit())
                Text(Fmt.pct(chg)).font(.system(size: 10.5).monospacedDigit()).foregroundStyle(changeColor(chg))
            }
            .frame(width: 84, alignment: .trailing)
        }
        .contentShape(Rectangle())
        .onTapGesture { store.toggleWatch(item.market, item.base) }
    }
}
