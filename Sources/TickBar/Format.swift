import Foundation

enum Fmt {
    private static var formatters: [Int: NumberFormatter] = [:]

    private static func formatter(_ digits: Int) -> NumberFormatter {
        if let f = formatters[digits] { return f }
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_US")
        f.minimumFractionDigits = digits
        f.maximumFractionDigits = digits
        formatters[digits] = f
        return f
    }

    /// Decimals scale with magnitude: $83,410 · $81.26 · $1.370 · $0.06153
    static func digits(for p: Double) -> Int {
        let a = abs(p)
        if a >= 1000 { return 0 }
        if a >= 10 { return 2 }
        if a >= 1 { return 3 }
        if a == 0 { return 2 }
        return min(10, max(4, 3 - Int(floor(log10(a)))))
    }

    static func number(_ v: Double, digits: Int) -> String {
        formatter(digits).string(from: NSNumber(value: v)) ?? "\(v)"
    }

    static func price(_ p: Double, _ cur: DisplayCurrency, compact: Bool = false, decimals: Int? = nil) -> String {
        if let decimals { return cur.symbol + number(p, digits: decimals) }
        return cur.symbol + (compact ? short(p) : number(p, digits: digits(for: p)))
    }

    static func short(_ v: Double) -> String {
        let a = abs(v)
        if a >= 1e9 { return number(v / 1e9, digits: 2) + "B" }
        if a >= 1e6 { return number(v / 1e6, digits: 2) + "M" }
        if a >= 1e4 { return number(v / 1e3, digits: 1) + "k" }
        return number(v, digits: digits(for: v))
    }

    /// Token amounts: 69.9k, 1,250, 0.05 (trailing zeros dropped).
    static func qty(_ v: Double) -> String {
        if abs(v) >= 1e4 { return short(v) }
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_US")
        f.maximumFractionDigits = abs(v) >= 1 ? 2 : 6
        return f.string(from: NSNumber(value: v)) ?? "\(v)"
    }

    static func money(_ v: Double, _ cur: DisplayCurrency) -> String {
        cur.symbol + number(v, digits: abs(v) >= 100 ? 0 : 2)
    }

    static func pct(_ x: Double?, digits: Int = 1) -> String {
        guard let x else { return "–" }
        let v = x * 100
        return (v >= 0 ? "+" : "−") + number(abs(v), digits: digits) + "%"
    }

    static func ago(_ d: Date, now: Date = Date()) -> String {
        let s = max(0, Int(now.timeIntervalSince(d)))
        if s < 60 { return "\(s)s ago" }
        if s < 3600 { return "\(s / 60)m ago" }
        return "\(s / 3600)h ago"
    }

    static func countdown(to d: Date, now: Date = Date()) -> String {
        let s = max(0, Int(d.timeIntervalSince(now)))
        return String(format: "%dh %02dm", s / 3600, (s % 3600) / 60)
    }
}
