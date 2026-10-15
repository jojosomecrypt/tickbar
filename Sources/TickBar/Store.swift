import AppKit
import Observation
import ServiceManagement
import UserNotifications

enum Health: Equatable {
    case connecting, live, lagging(Int), stale(Int)
    var rank: Int {
        switch self { case .live: 0; case .connecting: 1; case .lagging: 2; case .stale: 3 }
    }
}

@MainActor @Observable
final class Store {
    var config: Config {
        didSet { if config != oldValue { configChanged(from: oldValue) } }
    }

    private(set) var byBase: [Market: [String: [String: Instrument]]] = [:]
    private(set) var catalogCount = 0
    private(set) var assets: [String: BinanceAPI.Asset] = [:]
    private(set) var logos: [String: NSImage] = [:]
    private(set) var tickers: [String: Ticker] = [:]
    private(set) var perp: [String: PerpStats] = [:]
    private(set) var candles: [String: [Candle]] = [:]
    private(set) var fx: [DisplayCurrency: Double] = [.usd: 1]
    private(set) var dexInfo: [String: DexAPI.Pair] = [:]
    /// TickBar's own 5-minute samples for DEX tokens, used when GeckoTerminal candles aren't available.
    private(set) var dexHistory: [String: [Candle]] = [:]
    private(set) var clock = Date()
    var notificationsAllowed: Bool?

    @ObservationIgnored let spotConn = StreamConnection(url: "wss://stream.binance.com:9443/ws", heartbeat: "btcusdt@miniTicker")
    @ObservationIgnored let perpConn = StreamConnection(url: "wss://fstream.binance.com/market/ws", heartbeat: "btcusdt@markPrice@1s")
    @ObservationIgnored var flashes: [String: (until: Date, dir: Int)] = [:]
    @ObservationIgnored private var history: [String: [(Date, Double)]] = [:]
    @ObservationIgnored private var moveCooldown: [String: Date] = [:]
    @ObservationIgnored private var candleFetched: [String: Date] = [:]
    @ObservationIgnored private var logoLoading: Set<String> = []
    @ObservationIgnored private var keyToItem: [String: String] = [:]
    @ObservationIgnored private var lastFullSnapshot: Date?
    @ObservationIgnored private var timers: [Timer] = []
    @ObservationIgnored private var dexPolling = false

    private static let configKey = "config.v1"
    private static let supportDir: URL = {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("TickBar")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()
    private static let logoDir: URL = {
        let u = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("TickBar/logos")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.configKey),
           let c = try? JSONDecoder().decode(Config.self, from: data) {
            config = c
        } else {
            config = Config()
        }
    }

    // MARK: - Lifecycle

    func start() {
        spotConn.onEvent = { [weak self] in self?.handle($0, .spot) }
        perpConn.onEvent = { [weak self] in self?.handle($0, .perp) }
        spotConn.onReconnect = { [weak self] in Task { await self?.snapshotWatched() } }
        perpConn.onReconnect = { [weak self] in Task { await self?.snapshotWatched() } }
        loadCachedCatalog()
        loadDexHistory()
        rebuildSubscriptions()
        spotConn.connect()
        perpConn.connect()

        Task {
            await pollDex()
            await snapshotWatched()
            await loadCatalog()
            await loadFX()
        }
        refreshCandles()

        timers = [
            Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            },
            Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshCandles() }
            },
            Timer.scheduledTimer(withTimeInterval: 6, repeats: true) { [weak self] _ in
                Task { @MainActor in await self?.pollDex() }
            },
            Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    await self?.loadFX()
                    await self?.loadCatalog()
                }
            },
        ]
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.spotConn.reconnect()
                self?.perpConn.reconnect()
            }
        }
        if !config.alerts.isEmpty || config.moveAlert.enabled { requestNotifications() }
    }

    private func tick() {
        clock = Date()
        // Watchdog: a connection silent for 20s (heartbeat is BTC, ~1 msg/s) is dead.
        for c in [spotConn, perpConn] {
            let ref = c.lastMessage ?? c.connectedAt ?? .distantPast
            if clock.timeIntervalSince(ref) > 20 { c.reconnect() }
        }
    }

    private func configChanged(from old: Config) {
        if let data = try? JSONEncoder().encode(config) { UserDefaults.standard.set(data, forKey: Self.configKey) }
        if config.watchlist.map(\.id) != old.watchlist.map(\.id) || config.quote != old.quote {
            rebuildSubscriptions()
            refreshCandles()
            Task { await snapshotWatched() }
        }
        if (config.moveAlert.enabled && !old.moveAlert.enabled) || config.alerts.count > old.alerts.count {
            requestNotifications()
        }
    }

    // MARK: - Catalog

    private struct CatalogCache: Codable {
        var saved: Date
        var instruments: [Instrument]
        var assets: [BinanceAPI.Asset]
    }

    private var catalogFile: URL { Self.supportDir.appendingPathComponent("catalog.json") }

    private func loadCachedCatalog() {
        guard let data = try? Data(contentsOf: catalogFile),
              let c = try? JSONDecoder().decode(CatalogCache.self, from: data) else { return }
        apply(catalog: c.instruments, assets: c.assets)
    }

    /// Refreshes the market list at most once a day (spot exchangeInfo is ~6 MB).
    private func loadCatalog() async {
        if let data = try? Data(contentsOf: catalogFile),
           let c = try? JSONDecoder().decode(CatalogCache.self, from: data),
           Date().timeIntervalSince(c.saved) < 86_400, catalogCount > 0 { return }
        guard let inst = try? await BinanceAPI.catalog(), !inst.isEmpty else { return }
        let a = (try? await BinanceAPI.assets()) ?? Array(assets.values)
        apply(catalog: inst, assets: a)
        if let data = try? JSONEncoder().encode(CatalogCache(saved: Date(), instruments: inst, assets: a)) {
            try? data.write(to: catalogFile)
        }
        rebuildSubscriptions()
    }

    private func apply(catalog: [Instrument], assets list: [BinanceAPI.Asset]) {
        var m: [Market: [String: [String: Instrument]]] = [:]
        for i in catalog { m[i.market, default: [:]][i.base, default: [:]][i.quote] = i }
        byBase = m
        catalogCount = catalog.count
        assets = Dictionary(list.map { ($0.code, $0) }, uniquingKeysWith: { a, _ in a })
    }

    static let quotes = ["USDT", "USDC", "FDUSD"]

    /// Resolves a watch item to a tradable symbol, preferring the chosen quote and falling back to USDT.
    func instrument(for item: WatchItem) -> Instrument {
        if item.market == .dex {
            return Instrument(market: .dex, symbol: item.pair ?? item.base, base: item.base, quote: item.quoteSymbol ?? "USD")
        }
        if let qs = byBase[item.market]?[item.base] {
            if let i = qs[config.quote] ?? qs["USDT"] ?? qs["USDC"] ?? qs["FDUSD"] { return i }
        }
        return Instrument(market: item.market, symbol: item.base + "USDT", base: item.base, quote: "USDT")
    }

    func isListed(_ item: WatchItem) -> Bool {
        item.market == .dex || byBase.isEmpty || byBase[item.market]?[item.base] != nil
    }

    /// Picker rows: one per (market, base) that trades against a USD stablecoin.
    func catalogItems() -> [WatchItem] {
        var out: [WatchItem] = []
        for (market, bases) in byBase {
            for (base, qs) in bases where Self.quotes.contains(where: { qs[$0] != nil }) {
                out.append(WatchItem(market: market, base: base))
            }
        }
        return out
    }

    // MARK: - Names & logos

    private func assetCode(_ base: String) -> String {
        if assets[base] != nil { return base }
        for p in ["1000000", "100000", "10000", "1000", "1M"] where base.hasPrefix(p) {
            let s = String(base.dropFirst(p.count))
            if assets[s] != nil { return s }
        }
        return base
    }

    func name(_ base: String) -> String { assets[assetCode(base)]?.name ?? "" }

    func displayName(_ item: WatchItem) -> String {
        item.market == .dex ? (item.name ?? "") : name(item.base)
    }

    func logo(for item: WatchItem) -> NSImage? {
        guard item.market == .dex else { return logo(item.base) }
        let code = "dex-" + (item.address ?? item.base).lowercased()
        if let img = logos[code] { return img }
        if !logoLoading.contains(code), let s = item.logo, let url = URL(string: s) {
            logoLoading.insert(code)
            let file = Self.logoDir.appendingPathComponent("\(code).png")
            Task {
                if let img = NSImage(contentsOf: file) { self.logos[code] = img; return }
                guard let (data, _) = try? await URLSession.shared.data(from: url), let img = NSImage(data: data) else { return }
                try? data.write(to: file)
                self.logos[code] = img
            }
        }
        return nil
    }

    func logo(_ base: String) -> NSImage? {
        let code = assetCode(base)
        if let img = logos[code] { return img }
        loadLogo(code)
        return nil
    }

    private func loadLogo(_ code: String) {
        guard !logoLoading.contains(code) else { return }
        logoLoading.insert(code)
        let file = Self.logoDir.appendingPathComponent("\(code).png")
        if let img = NSImage(contentsOf: file) {
            Task { @MainActor in self.logos[code] = img }
            return
        }
        guard let s = assets[code]?.logo, let url = URL(string: s) else {
            logoLoading.remove(code) // retry once the asset list arrives
            return
        }
        Task {
            guard let (data, _) = try? await URLSession.shared.data(from: url), let img = NSImage(data: data) else { return }
            try? data.write(to: file)
            self.logos[code] = img
        }
    }

    // MARK: - Streams

    private func rebuildSubscriptions() {
        var map: [String: String] = [:]
        var s = Set<String>(), p = Set<String>()
        for item in config.watchlist {
            let inst = instrument(for: item)
            map[inst.key] = item.id
            let l = inst.symbol.lowercased()
            if inst.market == .dex {
                continue
            } else if inst.market == .spot {
                s.insert("\(l)@miniTicker")
            } else {
                p.insert("\(l)@miniTicker")
                p.insert("\(l)@markPrice@1s")
            }
        }
        keyToItem = map
        spotConn.setStreams(s)
        perpConn.setStreams(p)
    }

    private static func num(_ v: Any?) -> Double { (v as? String).flatMap(Double.init) ?? (v as? Double) ?? 0 }

    private func handle(_ e: [String: Any], _ m: Market) {
        guard let type = e["e"] as? String, let s = e["s"] as? String else { return }
        let key = "\(m.rawValue):\(s)"
        switch type {
        case "24hrMiniTicker":
            let p = Self.num(e["c"])
            guard p > 0 else { return }
            update(key, Ticker(price: p, open24: Self.num(e["o"]), high: Self.num(e["h"]), low: Self.num(e["l"]),
                               quoteVolume: Self.num(e["q"]), updated: Date()))
        case "markPriceUpdate":
            perp[key] = PerpStats(mark: Self.num(e["p"]), funding: Self.num(e["r"]),
                                  nextFunding: Date(timeIntervalSince1970: Self.num(e["T"]) / 1000))
        default: break
        }
    }

    private func update(_ key: String, _ new: Ticker) {
        var t = new
        if let old = tickers[key] {
            t.tickDir = old.tickDir
            if old.price != new.price {
                t.tickDir = new.price > old.price ? 1 : -1
                flashes[key] = (Date().addingTimeInterval(0.5), t.tickDir)
            }
        }
        tickers[key] = t
        if let itemID = keyToItem[key] { checkAlerts(itemID: itemID, key: key, price: t.price) }
    }

    private func merge(_ snap: [String: Ticker]) {
        let now = Date()
        for (k, t) in snap {
            // Never overwrite a fresher WebSocket tick with a REST snapshot.
            if let cur = tickers[k], now.timeIntervalSince(cur.updated) < 5 { continue }
            var v = t
            v.tickDir = tickers[k]?.tickDir ?? 0
            tickers[k] = v
        }
    }

    func snapshotWatched() async {
        let insts = config.watchlist.filter { $0.market != .dex && isListed($0) }.map(instrument(for:))
        let spot = insts.filter { $0.market == .spot }.map(\.symbol)
        let hasPerp = insts.contains { $0.market == .perp }
        async let s = try? BinanceAPI.spotTickers(spot)
        async let p = hasPerp ? try? BinanceAPI.perpTickers() : nil
        async let pr = hasPerp ? try? BinanceAPI.premium() : nil
        if let s = await s { merge(s) }
        if let p = await p { merge(p) }
        if let pr = await pr { perp.merge(pr) { cur, _ in cur } }
    }

    /// Full market snapshot for the coin picker, throttled to once a minute.
    func snapshotAll() async {
        if let t = lastFullSnapshot, Date().timeIntervalSince(t) < 60 { return }
        lastFullSnapshot = Date()
        async let s = try? BinanceAPI.spotTickers(nil)
        async let p = try? BinanceAPI.perpTickers()
        if let s = await s { merge(s) }
        if let p = await p { merge(p) }
    }

    private func refreshCandles() {
        let now = Date()
        for item in config.watchlist where isListed(item) {
            let inst = instrument(for: item)
            let every: TimeInterval = item.market == .dex ? 900 : 300
            if let t = candleFetched[inst.key], now.timeIntervalSince(t) < every { continue }
            candleFetched[inst.key] = now
            Task {
                if item.market == .dex {
                    let c = await DexAPI.candles(chain: item.chain ?? "", pool: inst.symbol)
                    if !c.isEmpty { self.candles[inst.key] = c } // else keep fallback history; retry in 15 min
                    return
                }
                if let c = try? await BinanceAPI.candles(inst), !c.isEmpty {
                    self.candles[inst.key] = c
                } else {
                    self.candleFetched[inst.key] = nil
                }
            }
        }
    }

    private func loadFX() async {
        if let r = try? await BinanceAPI.fx() { fx = r }
    }

    // MARK: - Derived values

    var health: Health {
        var conns = [spotConn]
        if config.watchlist.contains(where: { $0.market == .perp }) { conns.append(perpConn) }
        return conns.map { c -> Health in
            guard let last = c.lastMessage else {
                let since = Int(clock.timeIntervalSince(c.connectedAt ?? clock))
                return since > 10 ? .stale(since) : .connecting
            }
            let age = Int(clock.timeIntervalSince(last))
            return age < 5 ? .live : age < 20 ? .lagging(age) : .stale(age)
        }.max { $0.rank < $1.rank } ?? .connecting
    }

    var currency: DisplayCurrency { fx[config.currency] != nil ? config.currency : .usd }
    var fxRate: Double { fx[currency] ?? 1 }

    func ticker(_ item: WatchItem) -> Ticker? { tickers[instrument(for: item).key] }

    func priceText(_ item: WatchItem, compact: Bool = false) -> String {
        guard let t = ticker(item) else { return "–" }
        return Fmt.price(t.price * fxRate, currency, compact: compact, decimals: item.decimals)
    }

    func change(_ item: WatchItem, window: ChangeWindow? = nil) -> Double? {
        let inst = instrument(for: item)
        guard let t = tickers[inst.key] else { return nil }
        let ref: Double?
        switch window ?? config.changeWindow {
        case .h24:
            ref = t.open24
        case .h1:
            if inst.market == .dex, let c = dexInfo[inst.key]?.change1h { return c }
            let cutoff = Date().addingTimeInterval(-3600)
            ref = series(inst.key).first { $0.time >= cutoff }?.open
        case .today:
            let midnight = Calendar.current.startOfDay(for: Date())
            ref = series(inst.key).first { $0.time >= midnight }?.open
        }
        guard let ref, ref > 0 else { return nil }
        return t.price / ref - 1
    }

    func sparkline(_ item: WatchItem) -> [Double] {
        let inst = instrument(for: item)
        // 288 five-minute closes are too jagged at 60px; every 4th point = 20-minute resolution.
        let closes = series(inst.key).map(\.close)
        var v = stride(from: 0, to: closes.count, by: 4).map { closes[$0] }
        if let p = tickers[inst.key]?.price, !v.isEmpty { v.append(p) }
        return v
    }

    private func series(_ key: String) -> [Candle] {
        if let c = candles[key], !c.isEmpty { return c }
        return dexHistory[key] ?? []
    }

    func holdingsValue(_ item: WatchItem) -> Double? {
        guard item.holdings > 0, let t = ticker(item) else { return nil }
        return item.holdings * t.price * fxRate
    }

    var portfolioValue: Double? {
        let held = config.watchlist.filter { $0.holdings > 0 }
        guard !held.isEmpty else { return nil }
        return held.compactMap(holdingsValue).reduce(0, +)
    }

    var sortedWatchlist: [WatchItem] {
        switch config.sort {
        case .custom: return config.watchlist
        case .change: return config.watchlist.sorted { (change($0) ?? -.infinity) > (change($1) ?? -.infinity) }
        case .volume: return config.watchlist.sorted { (ticker($0)?.quoteVolume ?? 0) > (ticker($1)?.quoteVolume ?? 0) }
        }
    }

    func chartURL(_ item: WatchItem, site: ChartSite? = nil) -> URL {
        let i = instrument(for: item)
        if i.market == .dex {
            return URL(string: dexInfo[i.key]?.url ?? "https://dexscreener.com/\(item.chain ?? "")/\(i.symbol)")!
        }
        let s: String
        switch (site ?? config.chartSite, i.market) {
        case (.binance, .spot): s = "https://www.binance.com/en/trade/\(i.base)_\(i.quote)?type=spot"
        case (.binance, .perp): s = "https://www.binance.com/en/futures/\(i.symbol)"
        case (.tradingview, .spot): s = "https://www.tradingview.com/chart/?symbol=BINANCE:\(i.symbol)"
        case (.tradingview, .perp): s = "https://www.tradingview.com/chart/?symbol=BINANCE:\(i.symbol).P"
        case (_, .dex): s = "https://dexscreener.com"
        }
        return URL(string: s)!
    }

    func label(_ itemID: String) -> String {
        guard let item = config.watchlist.first(where: { $0.id == itemID }) else {
            return itemID.split(separator: ":").last.map(String.init) ?? itemID
        }
        return item.market == .perp ? "\(item.base) perp" : item.base
    }

    // MARK: - Watchlist edits

    func isWatched(_ market: Market, _ base: String) -> Bool {
        config.watchlist.contains { $0.market == market && $0.base == base }
    }

    func toggleWatch(_ market: Market, _ base: String) {
        if let i = config.watchlist.firstIndex(where: { $0.market == market && $0.base == base }) {
            let id = config.watchlist[i].id
            config.watchlist.remove(at: i)
            config.alerts.removeAll { $0.itemID == id }
        } else {
            let first = !config.watchlist.contains { $0.inMenuBar }
            config.watchlist.append(WatchItem(market: market, base: base, inMenuBar: first))
        }
    }

    func remove(_ id: String) {
        config.watchlist.removeAll { $0.id == id }
        config.alerts.removeAll { $0.itemID == id }
    }

    func dexItem(_ p: DexAPI.Pair) -> WatchItem {
        var w = WatchItem(market: .dex, base: p.baseSymbol)
        w.chain = p.chain; w.address = p.baseAddress; w.pair = p.pair; w.dexName = p.dex
        w.name = p.baseName; w.logo = p.image; w.quoteSymbol = p.quoteSymbol
        return w
    }

    func isWatched(_ id: String) -> Bool { config.watchlist.contains { $0.id == id } }

    func addDex(_ p: DexAPI.Pair) {
        let w = dexItem(p)
        guard !isWatched(w.id) else { return }
        dexInfo["dex:\(p.pair)"] = p
        applyDex(p)
        config.watchlist.append(w)
    }

    // MARK: - DEX polling

    func pollDex() async {
        guard !dexPolling else { return }
        let items = config.watchlist.filter { $0.market == .dex && $0.pair != nil }
        guard !items.isEmpty else { return }
        dexPolling = true
        defer { dexPolling = false }
        for (chain, group) in Dictionary(grouping: items, by: { $0.chain ?? "" }) {
            let pools = group.compactMap(\.pair)
            for start in stride(from: 0, to: pools.count, by: 30) {
                let batch = Array(pools[start..<min(start + 30, pools.count)])
                guard let ps = try? await DexAPI.refresh(chain: chain, pairs: batch) else { continue }
                ps.forEach(applyDex)
            }
        }
    }

    private func applyDex(_ p: DexAPI.Pair) {
        let key = "dex:\(p.pair)"
        dexInfo[key] = p
        let open = p.change24h.map { p.price / (1 + $0) } ?? 0
        update(key, Ticker(price: p.price, open24: open, high: 0, low: 0, quoteVolume: p.volume24, updated: Date()))
        // Own 5-minute history, kept for 24h, so DEX sparklines work without a candle API.
        var h = dexHistory[key] ?? []
        if h.last.map({ Date().timeIntervalSince($0.time) >= 300 }) ?? true {
            h.append(Candle(time: Date(), open: p.price, close: p.price))
            h.removeAll { Date().timeIntervalSince($0.time) > 86_400 }
            dexHistory[key] = h
            saveDexHistory()
        }
    }

    private var dexHistoryFile: URL { Self.supportDir.appendingPathComponent("dex-history.json") }

    private struct StoredCandle: Codable { let t: Date; let p: Double }

    private func loadDexHistory() {
        guard let data = try? Data(contentsOf: dexHistoryFile),
              let raw = try? JSONDecoder().decode([String: [StoredCandle]].self, from: data) else { return }
        let cutoff = Date().addingTimeInterval(-86_400)
        dexHistory = raw.mapValues { $0.filter { $0.t > cutoff }.map { Candle(time: $0.t, open: $0.p, close: $0.p) } }
    }

    private func saveDexHistory() {
        let raw = dexHistory.mapValues { $0.map { StoredCandle(t: $0.time, p: $0.close) } }
        if let data = try? JSONEncoder().encode(raw) { try? data.write(to: dexHistoryFile) }
    }

    func move(_ id: String, before target: String) {
        guard id != target, let from = config.watchlist.firstIndex(where: { $0.id == id }) else { return }
        var list = config.watchlist
        let item = list.remove(at: from)
        let to = list.firstIndex { $0.id == target } ?? list.count
        list.insert(item, at: to)
        config.watchlist = list
    }

    func move(_ id: String, by offset: Int) {
        guard let from = config.watchlist.firstIndex(where: { $0.id == id }) else { return }
        let to = from + offset
        guard config.watchlist.indices.contains(to) else { return }
        config.watchlist.swapAt(from, to)
    }

    func binding(_ id: String) -> WatchItem? { config.watchlist.first { $0.id == id } }

    func edit(_ id: String, _ change: (inout WatchItem) -> Void) {
        guard let i = config.watchlist.firstIndex(where: { $0.id == id }) else { return }
        change(&config.watchlist[i])
    }

    // MARK: - Alerts

    func addAlert(itemID: String, kind: PriceAlert.Kind, value: Double, frequency: PriceAlert.Frequency) {
        config.alerts.append(PriceAlert(itemID: itemID, kind: kind, value: value, frequency: frequency))
    }

    /// The number an alert compares against: price, or 24h change as a fraction.
    func alertMetric(_ kind: PriceAlert.Kind, _ t: Ticker) -> Double? {
        if kind.isPrice { return t.price }
        return t.open24 > 0 ? t.price / t.open24 - 1 : nil
    }

    func alertHit(_ a: PriceAlert, _ m: Double) -> Bool {
        switch a.kind {
        case .above, .changeAbove: return m >= a.value
        case .below, .changeBelow: return m <= a.value
        }
    }

    func alertTitle(_ a: PriceAlert, includeCoin: Bool = true) -> String {
        let coin = includeCoin ? label(a.itemID) + " " : ""
        switch a.kind {
        case .above: return "\(coin)rises above \(Fmt.price(a.value * fxRate, currency))"
        case .below: return "\(coin)drops below \(Fmt.price(a.value * fxRate, currency))"
        case .changeAbove: return "\(coin)24h change over \(Fmt.pct(a.value))"
        case .changeBelow: return "\(coin)24h change under \(Fmt.pct(a.value))"
        }
    }

    private func checkAlerts(itemID: String, key: String, price: Double) {
        guard let t = tickers[key] else { return }
        var alerts = config.alerts
        var changed = false
        let now = Date()
        for i in alerts.indices where alerts[i].itemID == itemID && alerts[i].armed {
            let a = alerts[i]
            guard let m = alertMetric(a.kind, t) else { continue }
            let hit = alertHit(a, m)
            var fire = false
            switch a.frequency {
            case .once:
                if hit { fire = true; alerts[i].armed = false }
            case .daily:
                if hit && !(a.lastFired.map { Calendar.current.isDate($0, inSameDayAs: now) } ?? false) { fire = true }
            case .always:
                if a.latched {
                    // Unlatch once the condition has cleared by a margin (0.5% of price, or 0.5
                    // percentage points of change), so a price hovering at the line can't spam.
                    let cleared: Bool
                    switch a.kind {
                    case .above: cleared = m < a.value * 0.995
                    case .below: cleared = m > a.value * 1.005
                    case .changeAbove: cleared = m < a.value - 0.005
                    case .changeBelow: cleared = m > a.value + 0.005
                    }
                    if cleared { alerts[i].latched = false; changed = true }
                } else if hit {
                    fire = true
                    alerts[i].latched = true
                }
            }
            guard fire else { continue }
            alerts[i].lastFired = now
            changed = true
            let body = "Now \(Fmt.price(price * fxRate, currency)) · 24h \(Fmt.pct(alertMetric(.changeAbove, t)))"
            switch a.kind {
            case .above: notify("\(label(itemID)) rose above \(Fmt.price(a.value * fxRate, currency))", body)
            case .below: notify("\(label(itemID)) fell below \(Fmt.price(a.value * fxRate, currency))", body)
            case .changeAbove, .changeBelow:
                notify("\(label(itemID)) \(Fmt.pct(m)) in 24h", body + " · your line \(Fmt.pct(a.value))")
            }
        }
        if changed { config.alerts = alerts }
        checkMove(itemID: itemID, key: key, price: price)
    }

    private func checkMove(itemID: String, key: String, price: Double) {
        let now = Date()
        let mc = config.moveAlert
        var h = history[key] ?? []
        if h.last.map({ now.timeIntervalSince($0.0) >= 10 }) ?? true { h.append((now, price)) }
        h.removeAll { now.timeIntervalSince($0.0) > Double(mc.minutes * 60) }
        history[key] = h
        guard mc.enabled, h.count >= 2 else { return }
        if let until = moveCooldown[key], until > now { return }
        let lo = h.map(\.1).min()!, hi = h.map(\.1).max()!
        let pct = mc.percent / 100
        var move: Double?
        if price / lo - 1 >= pct { move = price / lo - 1 }
        else if 1 - price / hi >= pct { move = price / hi - 1 }
        guard let move else { return }
        moveCooldown[key] = now.addingTimeInterval(Double(mc.cooldownMinutes * 60))
        notify("\(label(itemID)) \(Fmt.pct(move)) in \(mc.minutes)m",
               "Now \(Fmt.price(price * fxRate, currency))")
    }

    func requestNotifications() {
        guard Bundle.main.bundleIdentifier != nil else { notificationsAllowed = false; return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { ok, _ in
            Task { @MainActor in self.notificationsAllowed = ok }
        }
    }

    func notify(_ title: String, _ body: String) {
        guard Bundle.main.bundleIdentifier != nil else { NSSound.beep(); return }
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    // MARK: - Launch at login

    var launchAtLogin: Bool {
        get { _ = clock; return SMAppService.mainApp.status == .enabled }
        set {
            if newValue { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
            clock = Date()
        }
    }
}
