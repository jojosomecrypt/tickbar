import SwiftUI

struct PickerView: View {
    enum MarketFilter: String, CaseIterable { case all = "All", spot = "Spot", perp = "Perps" }

    @Environment(Store.self) private var store
    @State private var query = ""
    @State private var selectedOnly = false
    @State private var market: MarketFilter = .all

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
                        TextField("Search \(store.catalogCount > 0 ? "\(store.catalogItems().count) " : "")Binance markets", text: $query)
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

            if store.catalogCount == 0 {
                Spacer()
                ProgressView("Loading Binance markets…").controlSize(.small)
                Spacer()
            } else {
                List(rows) { item in
                    PickerRow(item: item)
                }
                .listStyle(.plain)
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
