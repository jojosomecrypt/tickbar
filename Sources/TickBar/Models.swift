import Foundation

enum Market: String, Codable, CaseIterable {
    case spot, perp, dex
    var label: String { ["spot": "Spot", "perp": "Perp", "dex": "DEX"][rawValue]! }
}

/// A coin the user follows. Keyed by market + base asset so switching the quote
/// currency (USDT/USDC/FDUSD) keeps the watchlist intact.
struct WatchItem: Codable, Hashable, Identifiable {
    var market: Market
    var base: String
    var inMenuBar: Bool = false
    var holdings: Double = 0
    /// Fixed decimal places for this coin's price; nil = automatic.
    var decimals: Int?
    // DEX tokens only (via DexScreener)
    var chain: String?
    var address: String?
    var pair: String?
    var dexName: String?
    var name: String?
    var logo: String?
    var quoteSymbol: String?

    var id: String {
        market == .dex ? "dex:\(chain ?? ""):\((address ?? base).lowercased())" : "\(market.rawValue):\(base)"
    }

    init(market: Market, base: String, inMenuBar: Bool = false, holdings: Double = 0) {
        self.market = market; self.base = base; self.inMenuBar = inMenuBar; self.holdings = holdings
    }

    // Tolerant: a missing field falls back to its default instead of failing the whole watchlist.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        market = try c.decode(Market.self, forKey: .market)
        base = try c.decode(String.self, forKey: .base)
        inMenuBar = try c.decodeIfPresent(Bool.self, forKey: .inMenuBar) ?? false
        holdings = try c.decodeIfPresent(Double.self, forKey: .holdings) ?? 0
        decimals = try c.decodeIfPresent(Int.self, forKey: .decimals)
        chain = try c.decodeIfPresent(String.self, forKey: .chain)
        address = try c.decodeIfPresent(String.self, forKey: .address)
        pair = try c.decodeIfPresent(String.self, forKey: .pair)
        dexName = try c.decodeIfPresent(String.self, forKey: .dexName)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        logo = try c.decodeIfPresent(String.self, forKey: .logo)
        quoteSymbol = try c.decodeIfPresent(String.self, forKey: .quoteSymbol)
    }
}

struct Instrument: Hashable, Codable {
    let market: Market
    let symbol: String
    let base: String
    let quote: String
    var key: String { "\(market.rawValue):\(symbol)" }
}

struct Ticker {
    var price: Double
    var open24: Double
    var high: Double
    var low: Double
    var quoteVolume: Double
    var updated: Date
    var tickDir: Int = 0
}

struct PerpStats {
    var mark: Double
    var funding: Double
    var nextFunding: Date
}

struct Candle {
    let time: Date
    let open: Double
    let close: Double
}

struct PriceAlert: Codable, Identifiable, Hashable {
    enum Kind: String, Codable, CaseIterable {
        case above, below, changeAbove, changeBelow
        var label: String {
            ["above": "Price rises above", "below": "Price drops below",
             "changeAbove": "24h change is over", "changeBelow": "24h change is under"][rawValue]!
        }
        var isPrice: Bool { self == .above || self == .below }
    }

    enum Frequency: String, Codable, CaseIterable {
        case once, daily, always
        var label: String { ["once": "Only once", "daily": "Once a day", "always": "Every time"][rawValue]! }
    }

    var id = UUID()
    var itemID: String
    var kind: Kind
    /// USD price for price kinds; a fraction (0.10 = +10%, -0.10 = -10%) for change kinds.
    var value: Double
    var frequency: Frequency = .once
    /// False only after an "Only once" alert has fired (until re-armed).
    var armed = true
    /// "Every time" alerts latch after firing and unlatch once the condition clears with margin.
    var latched = false
    var lastFired: Date?

    init(itemID: String, kind: Kind, value: Double, frequency: Frequency) {
        self.itemID = itemID; self.kind = kind; self.value = value; self.frequency = frequency
    }

    private enum CodingKeys: String, CodingKey {
        case id, itemID, kind, value, frequency, armed, latched, lastFired
        case direction, target, repeats // v1 alerts, decode only
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        itemID = try c.decode(String.self, forKey: .itemID)
        armed = try c.decodeIfPresent(Bool.self, forKey: .armed) ?? true
        latched = try c.decodeIfPresent(Bool.self, forKey: .latched) ?? false
        lastFired = try c.decodeIfPresent(Date.self, forKey: .lastFired)
        if let k = try c.decodeIfPresent(Kind.self, forKey: .kind) {
            kind = k
            value = try c.decode(Double.self, forKey: .value)
            frequency = try c.decodeIfPresent(Frequency.self, forKey: .frequency) ?? .once
        } else {
            kind = (try c.decodeIfPresent(String.self, forKey: .direction)) == "below" ? .below : .above
            value = try c.decode(Double.self, forKey: .target)
            let repeats = try c.decodeIfPresent(Bool.self, forKey: .repeats) ?? false
            frequency = repeats ? .always : .once
            if repeats { latched = !armed; armed = true }
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(itemID, forKey: .itemID)
        try c.encode(kind, forKey: .kind)
        try c.encode(value, forKey: .value)
        try c.encode(frequency, forKey: .frequency)
        try c.encode(armed, forKey: .armed)
        try c.encode(latched, forKey: .latched)
        try c.encodeIfPresent(lastFired, forKey: .lastFired)
    }
}

struct MoveAlertConfig: Codable, Equatable {
    var enabled = false
    var percent = 5.0
    var minutes = 15
    var cooldownMinutes = 30
}

enum ColorMode: String, Codable, CaseIterable {
    case change, tick, none
    var label: String { ["change": "By % change", "tick": "By last tick", "none": "No color"][rawValue]! }
}

enum ChangeWindow: String, Codable, CaseIterable {
    case h24, h1, today
    var label: String { ["h24": "24h", "h1": "1h", "today": "Today"][rawValue]! }
}

enum DisplayCurrency: String, Codable, CaseIterable {
    case usd, sgd, eur
    var label: String { rawValue.uppercased() }
    var symbol: String { ["usd": "$", "sgd": "S$", "eur": "€"][rawValue]! }
}

enum ChartSite: String, Codable, CaseIterable {
    case binance, tradingview
    var label: String { self == .binance ? "Binance" : "TradingView" }
}

enum SortMode: String, Codable, CaseIterable {
    case custom, change, volume
    var label: String { ["custom": "My order", "change": "% change", "volume": "Volume"][rawValue]! }
}

enum BarFont: String, Codable, CaseIterable {
    case system, mono
    var label: String { self == .system ? "System" : "Monospaced" }
}

struct Config: Codable, Equatable {
    var watchlist: [WatchItem] = [
        WatchItem(market: .spot, base: "BTC", inMenuBar: true),
        WatchItem(market: .spot, base: "ETH"),
        WatchItem(market: .spot, base: "SOL"),
        WatchItem(market: .spot, base: "BNB"),
        WatchItem(market: .spot, base: "HYPE", inMenuBar: true),
        WatchItem(market: .spot, base: "EDEN", inMenuBar: true),
    ]
    // Data
    var quote = "USDT"
    var currency: DisplayCurrency = .usd
    var changeWindow: ChangeWindow = .h24
    // Menu bar
    var barShowLogo = false
    var barShowSymbol = true
    var barShowPrice = true
    var barShowChange = false
    var barCompact = false
    var barFont: BarFont = .system
    var colorMode: ColorMode = .change
    var flashOnTick = true
    var rotate = false
    var rotateCount = 3
    var rotateSeconds = 5
    var barShowPortfolio = false
    // Dropdown
    var sort: SortMode = .custom
    var chartSite: ChartSite = .binance
    var showSparklines = true
    // Alerts
    var alerts: [PriceAlert] = []
    var moveAlert = MoveAlertConfig()

    init() {}

    // Tolerant decoding: any missing key falls back to its default, so adding or
    // removing settings later never wipes a user's saved config.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        func v<T: Decodable>(_ k: CodingKeys, _ def: T) -> T { ((try? c.decodeIfPresent(T.self, forKey: k)) ?? nil) ?? def }
        watchlist = v(.watchlist, d.watchlist)
        quote = v(.quote, d.quote)
        currency = v(.currency, d.currency)
        changeWindow = v(.changeWindow, d.changeWindow)
        barShowLogo = v(.barShowLogo, d.barShowLogo)
        barShowSymbol = v(.barShowSymbol, d.barShowSymbol)
        barShowPrice = v(.barShowPrice, d.barShowPrice)
        barShowChange = v(.barShowChange, d.barShowChange)
        barCompact = v(.barCompact, d.barCompact)
        barFont = v(.barFont, d.barFont)
        colorMode = v(.colorMode, d.colorMode)
        flashOnTick = v(.flashOnTick, d.flashOnTick)
        rotate = v(.rotate, d.rotate)
        rotateCount = v(.rotateCount, d.rotateCount)
        rotateSeconds = v(.rotateSeconds, d.rotateSeconds)
        barShowPortfolio = v(.barShowPortfolio, d.barShowPortfolio)
        sort = v(.sort, d.sort)
        chartSite = v(.chartSite, d.chartSite)
        showSparklines = v(.showSparklines, d.showSparklines)
        alerts = v(.alerts, d.alerts)
        moveAlert = v(.moveAlert, d.moveAlert)
    }
}
