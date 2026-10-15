import Foundation

/// DEX tokens (any chain) via DexScreener. No WebSocket exists, so prices are polled;
/// the public pairs endpoint allows 300 requests/min, we use ~10/min per chain.
enum DexAPI {
    struct Pair {
        let chain: String
        let pair: String
        let dex: String
        let url: String
        let price: Double
        let change1h: Double?
        let change24h: Double?
        let volume24: Double
        let liquidity: Double
        let baseSymbol: String
        let baseName: String
        let baseAddress: String
        let quoteSymbol: String
        let image: String?
    }

    private static let base = "https://api.dexscreener.com/latest/dex"

    static func isAddress(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.range(of: "^0x[0-9a-fA-F]{40}$", options: .regularExpression) != nil { return true }
        return t.range(of: "^[1-9A-HJ-NP-Za-km-z]{32,44}$", options: .regularExpression) != nil // Solana-style
    }

    private static func parse(_ p: [String: Any]) -> Pair? {
        func d(_ v: Any?) -> Double? { (v as? String).flatMap(Double.init) ?? (v as? Double) }
        guard let chain = p["chainId"] as? String, let pair = p["pairAddress"] as? String,
              let price = d(p["priceUsd"]), price > 0,
              let bt = p["baseToken"] as? [String: Any], let qt = p["quoteToken"] as? [String: Any] else { return nil }
        let ch = p["priceChange"] as? [String: Any] ?? [:]
        return Pair(chain: chain, pair: pair, dex: p["dexId"] as? String ?? "",
                    url: p["url"] as? String ?? "https://dexscreener.com/\(chain)/\(pair)",
                    price: price, change1h: d(ch["h1"]).map { $0 / 100 }, change24h: d(ch["h24"]).map { $0 / 100 },
                    volume24: d((p["volume"] as? [String: Any])?["h24"]) ?? 0,
                    liquidity: d((p["liquidity"] as? [String: Any])?["usd"]) ?? 0,
                    baseSymbol: bt["symbol"] as? String ?? "?", baseName: bt["name"] as? String ?? "",
                    baseAddress: bt["address"] as? String ?? "", quoteSymbol: qt["symbol"] as? String ?? "",
                    image: (p["info"] as? [String: Any])?["imageUrl"] as? String)
    }

    private static func pairs(_ url: String) async throws -> [Pair] {
        let j = try await BinanceAPI.get(url)
        return ((j as? [String: Any])?["pairs"] as? [[String: Any]] ?? []).compactMap(parse)
    }

    /// One result per token: its most-traded pool where it is the base token
    /// (by 24h volume, not liquidity, which is easy to fake on thin pools).
    private static func bestPerToken(_ ps: [Pair]) -> [Pair] {
        var best: [String: Pair] = [:]
        for p in ps {
            let k = "\(p.chain):\(p.baseAddress.lowercased())"
            if let cur = best[k], cur.volume24 >= p.volume24 { continue }
            best[k] = p
        }
        return best.values.sorted { $0.volume24 > $1.volume24 }
    }

    static func lookup(address: String) async throws -> [Pair] {
        let a = address.trimmingCharacters(in: .whitespaces)
        let ps = try await pairs("\(base)/tokens/\(a)").filter { $0.baseAddress.lowercased() == a.lowercased() }
        return bestPerToken(ps)
    }

    static func search(_ query: String) async throws -> [Pair] {
        let q = query.trimmingCharacters(in: .whitespaces).addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        return Array(bestPerToken(try await pairs("\(base)/search?q=\(q)")).prefix(10))
    }

    /// Batch refresh: up to 30 pools per request, all on one chain.
    static func refresh(chain: String, pairs list: [String]) async throws -> [Pair] {
        try await pairs("\(base)/pairs/\(chain)/\(list.joined(separator: ","))")
    }

    /// Best-effort 24h candles from GeckoTerminal (rate-limited, so callers fall back to
    /// TickBar's own sampled history when this returns nothing).
    static func candles(chain: String, pool: String) async -> [Candle] {
        let network = ["ethereum": "eth", "polygon": "polygon_pos", "avalanche": "avax"][chain] ?? chain
        let url = "https://api.geckoterminal.com/api/v2/networks/\(network)/pools/\(pool)/ohlcv/minute?aggregate=15&limit=96"
        guard let j = try? await BinanceAPI.get(url),
              let list = (((j as? [String: Any])?["data"] as? [String: Any])?["attributes"] as? [String: Any])?["ohlcv_list"] as? [[Double]]
        else { return [] }
        return list.filter { $0.count > 4 }
            .map { Candle(time: Date(timeIntervalSince1970: $0[0]), open: $0[1], close: $0[4]) }
            .sorted { $0.time < $1.time }
    }
}
