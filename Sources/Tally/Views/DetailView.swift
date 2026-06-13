import SwiftUI

/// The popover shown when the menu bar item is clicked. Uses a custom Gruvbox-styled tab bar
/// (rather than the native TabView chrome, which can't be fully recoloured) plus a state-driven
/// content switch.
struct DetailView: View {
    @EnvironmentObject var vm: NetworkViewModel
    @State private var tab: Tab = .network

    enum Tab: String, CaseIterable, Identifiable {
        case network = "Network"
        case connection = "Connection"
        case stats = "Stats"
        case settings = "Settings"
        var id: String {
            rawValue
        }

        var symbol: String {
            switch self {
            case .network: return "chart.xyaxis.line"
            case .connection: return "wifi"
            case .stats: return "chart.bar.fill"
            case .settings: return "gearshape"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider().overlay(Theme.divider)
            content
        }
        .background(Theme.background)
        .foregroundStyle(Theme.primaryText)
        .tint(Theme.aqua)
        .preferredColorScheme(.dark) // pin dark so Gruvbox bg/fg read correctly regardless of system
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(Tab.allCases) { t in
                Button {
                    tab = t
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: t.symbol).font(.system(size: 14))
                        Text(t.rawValue).font(.caption2)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .foregroundStyle(tab == t ? Theme.aqua : Theme.secondaryText)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(tab == t ? Theme.card : .clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Theme.background)
    }

    @ViewBuilder private var content: some View {
        switch tab {
        case .network: NetworkTab()
        case .connection: ConnectionTab()
        case .stats: StatsTab()
        case .settings: SettingsView()
        }
    }
}
