import SwiftUI

struct SettingsView: View {
    @Environment(Store.self) private var store

    var body: some View {
        @Bindable var store = store
        Form {
            Section("Menu bar") {
                HStack {
                    Toggle("Logo", isOn: $store.config.barShowLogo)
                    Toggle("Symbol", isOn: $store.config.barShowSymbol)
                    Toggle("Price", isOn: $store.config.barShowPrice)
                    Toggle("% change", isOn: $store.config.barShowChange)
                }
                .toggleStyle(.checkbox)
                Picker("Color", selection: $store.config.colorMode) {
                    ForEach(ColorMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Picker("Font", selection: $store.config.barFont) {
                    ForEach(BarFont.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Toggle("Compact numbers (83.3k)", isOn: $store.config.barCompact)
                Toggle("Flash on each price tick", isOn: $store.config.flashOnTick)
                Toggle("Show holdings total (Σ)", isOn: $store.config.barShowPortfolio)
                Toggle("Rotate through coins", isOn: $store.config.rotate)
                if store.config.rotate {
                    Stepper("Show \(store.config.rotateCount) at a time", value: $store.config.rotateCount, in: 1...10)
                    Stepper("Next set every \(store.config.rotateSeconds)s", value: $store.config.rotateSeconds, in: 2...60)
                }
            }

            Section {
                Picker("Pair", selection: $store.config.quote) {
                    ForEach(Store.quotes, id: \.self) { Text($0).tag($0) }
                }
                Picker("Show prices in", selection: $store.config.currency) {
                    ForEach(DisplayCurrency.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Picker("% change over", selection: $store.config.changeWindow) {
                    ForEach(ChangeWindow.allCases, id: \.self) { Text($0.label).tag($0) }
                }
            } header: {
                Text("Prices")
            } footer: {
                Text("Coins without a pair in the chosen stablecoin fall back to USDT. Non-USD prices are converted at the daily FX rate.")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
            }

            Section("Dropdown") {
                Picker("⌘-click a coin opens", selection: $store.config.chartSite) {
                    ForEach(ChartSite.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Toggle("24h sparklines", isOn: $store.config.showSparklines)
            }

            Section("General") {
                Toggle("Launch at login", isOn: $store.launchAtLogin)
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")
                LabeledContent("Data", value: "Binance WebSocket, live")
            }
        }
        .formStyle(.grouped)
        .controlSize(.small)
    }
}
