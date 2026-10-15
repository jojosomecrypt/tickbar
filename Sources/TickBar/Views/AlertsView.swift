import SwiftUI

struct AlertsView: View {
    @Environment(Store.self) private var store

    var body: some View {
        @Bindable var store = store
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if store.notificationsAllowed == false {
                    HStack {
                        Image(systemName: "bell.slash").foregroundStyle(.orange)
                        Text("Notifications are off for TickBar. Alerts can't reach you until you allow them.")
                            .font(.system(size: 11.5))
                        Spacer()
                        Button("Open Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                        }
                        .controlSize(.small)
                    }
                    .padding(10)
                    .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                }

                section("Price alerts")
                if store.config.alerts.isEmpty {
                    Text("None yet. Add one here or from a coin's detail panel in the watchlist.")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                ForEach(store.config.alerts) { AlertLine(alert: $0) }

                AlertForm()

                Divider()

                section("Big move alert")
                Toggle("Notify when any coin on my watchlist moves fast", isOn: $store.config.moveAlert.enabled)
                Group {
                    Stepper(value: $store.config.moveAlert.percent, in: 1...50, step: 0.5) {
                        Text("Move of at least **\(Fmt.number(store.config.moveAlert.percent, digits: 1))%**")
                    }
                    Stepper(value: $store.config.moveAlert.minutes, in: 1...60) {
                        Text("Within **\(store.config.moveAlert.minutes) min**")
                    }
                    Stepper(value: $store.config.moveAlert.cooldownMinutes, in: 5...240, step: 5) {
                        Text("Then stay quiet on that coin for **\(store.config.moveAlert.cooldownMinutes) min**")
                    }
                }
                .disabled(!store.config.moveAlert.enabled)
                .font(.system(size: 12))
                Text("Measured from the low (pumps) or high (dumps) inside the window. Needs the app running for the full window first.")
                    .font(.system(size: 10.5)).foregroundStyle(.tertiary)

                Divider()

                Button("Send a test notification") {
                    store.requestNotifications()
                    store.notify("TickBar test", "Alerts will look like this.")
                }
                .controlSize(.small)
            }
            .padding(14)
        }
    }

    private func section(_ title: String) -> some View {
        Text(title).font(.system(size: 13, weight: .semibold))
    }
}

struct AlertForm: View {
    @Environment(Store.self) private var store
    var fixedItemID: String?
    @State private var coin = ""
    @State private var kind: PriceAlert.Kind = .above
    @State private var value: Double?
    @State private var frequency: PriceAlert.Frequency = .once

    private var itemID: String { fixedItemID ?? coin }
    private var ticker: Ticker? { store.binding(itemID).flatMap(store.ticker) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if fixedItemID == nil {
                    Picker("", selection: $coin) {
                        ForEach(store.config.watchlist) { Text(store.label($0.id)).tag($0.id) }
                    }
                    .labelsHidden().frame(width: 112)
                }
                Picker("", selection: $kind) {
                    ForEach(PriceAlert.Kind.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden().fixedSize()
                HStack(spacing: 3) {
                    if kind.isPrice { Text(store.currency.symbol).foregroundStyle(.secondary) }
                    TextField(kind.isPrice ? "price" : (kind == .changeAbove ? "10" : "-10"), value: $value, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(add)
                    if !kind.isPrice { Text("%").foregroundStyle(.secondary) }
                }
            }
            HStack(spacing: 6) {
                Picker("", selection: $frequency) {
                    ForEach(PriceAlert.Frequency.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden().fixedSize()
                Text(frequencyHint).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                Button("Add", action: add).disabled(stored == nil)
            }
            Text(hint).font(.system(size: 10.5)).foregroundStyle(.tertiary)
        }
        .onAppear { if coin.isEmpty { coin = store.config.watchlist.first?.id ?? "" } }
    }

    /// What gets saved: USD price, or a signed fraction for change alerts.
    private var stored: Double? {
        guard let value, value != 0, ticker != nil, !itemID.isEmpty else { return nil }
        switch kind {
        case .above, .below: return value > 0 ? value / store.fxRate : nil
        case .changeAbove: return value / 100
        case .changeBelow: return value > 0 ? -value / 100 : value / 100
        }
    }

    private var frequencyHint: String {
        switch frequency {
        case .once: return "Fires once, then stops"
        case .daily: return "At most once per day"
        case .always: return "Every crossing, resets after a 0.5% pullback"
        }
    }

    private var hint: String {
        guard let t = ticker else { return "Pick a coin." }
        let coinName = store.label(itemID)
        let price = Fmt.price(t.price * store.fxRate, store.currency)
        let change = Fmt.pct(store.alertMetric(.changeAbove, t))
        guard let v = stored else { return "\(coinName) is \(price) now, \(change) over 24h." }
        let probe = PriceAlert(itemID: itemID, kind: kind, value: v, frequency: frequency)
        if let m = store.alertMetric(kind, t), store.alertHit(probe, m) {
            return "Already true right now, so it will fire immediately."
        }
        if kind.isPrice { return "\(coinName) is \(price) now (\(Fmt.pct(v / t.price - 1)) to go)." }
        return "\(coinName) is \(change) over 24h now."
    }

    private func add() {
        guard let v = stored else { return }
        store.addAlert(itemID: itemID, kind: kind, value: v, frequency: frequency)
        value = nil
    }
}

struct AlertLine: View {
    @Environment(Store.self) private var store
    let alert: PriceAlert
    var compact = false

    var body: some View {
        let up = alert.kind == .above || alert.kind == .changeAbove
        HStack(spacing: 8) {
            Image(systemName: up ? "arrow.up.right" : "arrow.down.right")
                .foregroundStyle(up ? .green : .red)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(store.alertTitle(alert, includeCoin: !compact).capitalizedFirst)
                    .font(.system(size: 12, weight: .medium))
                Text(status).font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            Spacer()
            if alert.frequency == .once && !alert.armed {
                Button("Re-arm") { edit { $0.armed = true } }.controlSize(.small)
            }
            Menu {
                Picker("Frequency", selection: Binding(get: { alert.frequency }, set: { f in edit { $0.frequency = f; $0.armed = true; $0.latched = false } })) {
                    ForEach(PriceAlert.Frequency.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Text(alert.frequency.label).font(.system(size: 11))
            }
            .menuStyle(.borderlessButton).fixedSize()
            .help("How often this alert can fire")
            Button {
                store.config.alerts.removeAll { $0.id == alert.id }
            } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .help("Delete alert")
        }
        .padding(.vertical, 3)
    }

    private var status: String {
        var parts: [String] = []
        let t = store.binding(alert.itemID).flatMap(store.ticker)
        if let f = alert.lastFired { parts.append("fired \(Fmt.ago(f, now: store.clock))") }
        switch alert.frequency {
        case .once where !alert.armed:
            parts.append("done, re-arm to use again")
            return parts.joined(separator: " · ")
        case .daily where alert.lastFired.map { Calendar.current.isDateInToday($0) } ?? false:
            parts.append("next chance tomorrow")
            return parts.joined(separator: " · ")
        case .always where alert.latched:
            parts.append("resets once it pulls back 0.5%")
            return parts.joined(separator: " · ")
        default: break
        }
        if let t, let m = store.alertMetric(alert.kind, t) {
            parts.append(alert.kind.isPrice ? "\(Fmt.pct(alert.value / m - 1)) away" : "now \(Fmt.pct(m))")
        }
        return parts.joined(separator: " · ")
    }

    private func edit(_ change: (inout PriceAlert) -> Void) {
        guard let i = store.config.alerts.firstIndex(where: { $0.id == alert.id }) else { return }
        change(&store.config.alerts[i])
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
