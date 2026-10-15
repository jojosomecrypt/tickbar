import Foundation

/// REST calls. Live prices come from WebSockets; REST is only for the catalog,
/// initial snapshots, candles (sparklines / 1h / today change) and FX.
enum BinanceAPI {
    static let spot = "https://api.binance.com"
    static let futures = "https://fapi.binance.com"

    struct Asset: Codable { let code: String; let name: String; let logo: String? }

    static func get(_ url: String) async throws -> Any {
        guard let u = URL(string: url) else { throw URLError(.badURL) }
        var req = URLRequest(url: u, timeoutInterval: 20)
        req.setValue("TickBar/1.0", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let h = resp as? HTTPURLResponse, h.statusCode != 200 { throw URLError(.badServerResponse) }
        return try JSONSerialization.jsonObject(with: data)
    }

    private static func d(_ v: Any?) -> Double { (v as? String).flatMap(Double.init) ?? (v as? Double) ?? 0 }

    static func catalog() async throws -> [Instrument] {
        async let s = get("\(spot)/api/v3/exchangeInfo?permissions=SPOT&symbolStatus=TRADING")
        async let f = get("\(futures)/fapi/v1/exchangeInfo")
        var out: [Instrument] = []
        for x in ((try await s) as? [String: Any])?["symbols"] as? [[String: Any]] ?? [] {
            guard x["status"] as? String == "TRADING", let sym = x["symbol"] as? String,
                  let b = x["baseAsset"] as? String, let q = x["quoteAsset"] as? String else { continue }
            out.append(Instrument(market: .spot, symbol: sym, base: b, quote: q))
        }
        for x in ((try await f) as? [String: Any])?["symbols"] as? [[String: Any]] ?? [] {
            guard x["status"] as? String == "TRADING", x["contractType"] as? String == "PERPETUAL",
                  let sym = x["symbol"] as? String, let b = x["baseAsset"] as? String,
                  let q = x["quoteAsset"] as? String else { continue }
            out.append(Instrument(market: .perp, symbol: sym, base: b, quote: q))
        }
        return out
    }

    static func assets() async throws -> [Asset] {
        let j = try await get("https://www.binance.com/bapi/asset/v2/public/asset/asset/get-all-asset")
        return ((j as? [String: Any])?["data"] as? [[String: Any]] ?? []).compactMap {
            guard let c = $0["assetCode"] as? String else { return nil }
            return Asset(code: c, name: $0["assetName"] as? String ?? c, logo: $0["logoUrl"] as? String)
        }
    }

    private static func tickers(_ j: Any, market: Market) -> [String: Ticker] {
        var out: [String: Ticker] = [:]
        let now = Date()
        for x in j as? [[String: Any]] ?? [] {
            guard let sym = x["symbol"] as? String else { continue }
            let p = d(x["lastPrice"])
            guard p > 0 else { continue }
            out["\(market.rawValue):\(sym)"] = Ticker(price: p, open24: d(x["openPrice"]), high: d(x["highPrice"]),
                                                      low: d(x["lowPrice"]), quoteVolume: d(x["quoteVolume"]), updated: now)
        }
        return out
    }

    /// `symbols == nil` fetches every spot market (~1 MB); used only for the coin picker.
    static func spotTickers(_ symbols: [String]?) async throws -> [String: Ticker] {
        var url = "\(spot)/api/v3/ticker/24hr?type=MINI"
        if let symbols {
            if symbols.isEmpty { return [:] }
            let list = "[" + symbols.map { "\"\($0)\"" }.joined(separator: ",") + "]"
            url += "&symbols=" + (list.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? list)
        }
        return tickers(try await get(url), market: .spot)
    }

    static func perpTickers() async throws -> [String: Ticker] {
        tickers(try await get("\(futures)/fapi/v1/ticker/24hr"), market: .perp)
    }

    static func premium() async throws -> [String: PerpStats] {
        var out: [String: PerpStats] = [:]
        for x in try await get("\(futures)/fapi/v1/premiumIndex") as? [[String: Any]] ?? [] {
            guard let sym = x["symbol"] as? String else { continue }
            out["perp:\(sym)"] = PerpStats(mark: d(x["markPrice"]), funding: d(x["lastFundingRate"]),
                                          nextFunding: Date(timeIntervalSince1970: d(x["nextFundingTime"]) / 1000))
        }
        return out
    }

    /// 24h of 5-minute candles: drives the sparkline and the 1h / since-midnight change.
    static func candles(_ inst: Instrument) async throws -> [Candle] {
        let url = inst.market == .spot
            ? "\(spot)/api/v3/klines?symbol=\(inst.symbol)&interval=5m&limit=288"
            : "\(futures)/fapi/v1/klines?symbol=\(inst.symbol)&interval=5m&limit=288"
        return (try await get(url) as? [[Any]] ?? []).compactMap { k in
            guard k.count > 4, let t = k[0] as? Double else { return nil }
            return Candle(time: Date(timeIntervalSince1970: t / 1000), open: d(k[1]), close: d(k[4]))
        }
    }

    static func fx() async throws -> [DisplayCurrency: Double] {
        let j = try await get("https://open.er-api.com/v6/latest/USD")
        let rates = (j as? [String: Any])?["rates"] as? [String: Any] ?? [:]
        var out: [DisplayCurrency: Double] = [.usd: 1]
        for c in DisplayCurrency.allCases where c != .usd {
            if let r = rates[c.rawValue.uppercased()] as? Double { out[c] = r }
        }
        return out
    }
}
