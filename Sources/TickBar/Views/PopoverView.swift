import SwiftUI

enum Tab: String, CaseIterable, Identifiable {
    case watchlist = "Watchlist", add = "Add coins", alerts = "Alerts", settings = "Settings"
    var id: String { rawValue }
}

struct PopoverView: View {
    @Environment(Store.self) private var store
    @State private var tab: Tab
    private let expanded: String?

    init(tab: Tab = .watchlist, expanded: String? = nil) {
        _tab = State(initialValue: tab)
        self.expanded = expanded
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(10)

            Divider()

            Group {
                switch tab {
                case .watchlist: WatchlistView(expanded: expanded)
                case .add: PickerView()
                case .alerts: AlertsView()
                case .settings: SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            HStack {
                HealthBadge()
                Spacer()
                if let v = store.portfolioValue {
                    Text("Holdings \(Fmt.money(v, store.currency))").foregroundStyle(.secondary)
                }
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                    .buttonStyle(.borderless)
                    .help("Quit TickBar")
            }
            .font(.system(size: 11))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(width: 440, height: 580)
    }
}
