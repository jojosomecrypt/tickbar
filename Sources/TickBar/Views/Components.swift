import SwiftUI

struct CoinLogo: View {
    @Environment(Store.self) private var store
    let base: String
    var size: CGFloat = 18

    var body: some View {
        if let img = store.logo(base) {
            Image(nsImage: img).resizable().interpolation(.high).frame(width: size, height: size).clipShape(Circle())
        } else {
            Circle().fill(.quaternary)
                .overlay(Text(String(base.prefix(1))).font(.system(size: size * 0.5, weight: .semibold)).foregroundStyle(.secondary))
                .frame(width: size, height: size)
        }
    }
}

struct Sparkline: View {
    let values: [Double]

    var body: some View {
        GeometryReader { g in
            if values.count > 1, let lo = values.min(), let hi = values.max() {
                let range = max(hi - lo, abs(hi) * 1e-9)
                Path { p in
                    for (i, v) in values.enumerated() {
                        let pt = CGPoint(x: g.size.width * CGFloat(i) / CGFloat(values.count - 1),
                                         y: g.size.height * (1 - CGFloat((v - lo) / range)))
                        i == 0 ? p.move(to: pt) : p.addLine(to: pt)
                    }
                }
                .stroke(values.last! >= values.first! ? Color.green : Color.red,
                        style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
            }
        }
    }
}

struct MarketBadge: View {
    let market: Market

    var body: some View {
        Text(market == .perp ? "PERP" : "SPOT")
            .font(.system(size: 8.5, weight: .bold))
            .padding(.horizontal, 4).padding(.vertical, 1)
            .foregroundStyle(market == .perp ? Color.orange : Color.secondary)
            .background((market == .perp ? Color.orange : Color.secondary).opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
    }
}

struct HealthBadge: View {
    @Environment(Store.self) private var store

    var body: some View {
        let (color, text): (Color, String) = switch store.health {
        case .live: (.green, "Live · Binance")
        case .connecting: (.gray, "Connecting…")
        case .lagging(let s): (.yellow, "Lagging · \(s)s")
        case .stale(let s): (.red, "Stale · \(s)s · reconnecting")
        }
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).foregroundStyle(.secondary)
        }
    }
}

func changeColor(_ x: Double?) -> Color {
    guard let x else { return .secondary }
    return x >= 0 ? .green : .red
}

extension View {
    @ViewBuilder func `if`<V: View>(_ cond: Bool, _ transform: (Self) -> V) -> some View {
        if cond { transform(self) } else { self }
    }
}
