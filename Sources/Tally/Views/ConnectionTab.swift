import Charts
import SwiftUI

/// Connection quality overview: quality score, latency to gateway & internet, a quality/latency
/// history graph, connection details (type, VPN), and a live per-interface usage breakdown.
struct ConnectionTab: View {
    @EnvironmentObject var vm: NetworkViewModel

    enum Range: String, CaseIterable, Identifiable {
        case hour = "Hour", day = "Day", week = "Week", month = "Month"
        var id: String {
            rawValue
        }

        var interval: TimeInterval {
            switch self {
            case .hour: return 3600
            case .day: return 86400
            case .week: return 7 * 86400
            case .month: return 30 * 86400
            }
        }

        var usesRollup: Bool {
            self == .week || self == .month
        }
    }

    @State private var range: Range = .hour
    @State private var history: [QualityPoint] = []
    private let db = Database.shared
    private let refresh = Timer.publish(every: 10, on: .main, in: .common).autoconnect()

    private static let dayFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt
    }()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                qualityAndLatency
                Divider()
                historySection
                Divider()
                connectionSection
                Divider()
                interfacesSection
            }
            .padding()
        }
        .onAppear(perform: reloadHistory)
        .onChange(of: range) { _, _ in reloadHistory() }
        .onReceive(refresh) { _ in reloadHistory() }
    }

    // MARK: - Quality / latency history

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("History").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Picker("Range", selection: $range) {
                    ForEach(Range.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 220)
            }
            if history.isEmpty {
                RoundedRectangle(cornerRadius: 6).fill(Theme.bg2)
                    .frame(height: 120)
                    .overlay(Text("Collecting quality history…")
                        .font(.caption).foregroundStyle(.secondary))
            } else {
                qualityChart.frame(height: 120)
            }
        }
    }

    private var qualityChart: some View {
        Chart {
            // Quality score (0–100) as a filled area on a secondary axis feel; latency as a line.
            ForEach(history) { p in
                AreaMark(
                    x: .value("Time", p.time),
                    y: .value("Score", p.score),
                    series: .value("s", "score")
                )
                .foregroundStyle(Theme.green.opacity(0.18))
            }
            ForEach(history) { p in
                LineMark(
                    x: .value("Time", p.time),
                    y: .value("Latency", p.latencyMs),
                    series: .value("s", "latency")
                )
                .foregroundStyle(Theme.yellow)
            }
        }
        .chartForegroundStyleScale([
            "Score": Theme.green, "Latency": Theme.yellow
        ])
        .chartYAxis {
            AxisMarks { value in
                AxisValueLabel { if let v = value.as(Double.self) { Text("\(Int(v))") } }
            }
        }
        .chartLegend(position: .top, alignment: .leading, spacing: 8)
    }

    private func reloadHistory() {
        if range.usesRollup {
            let since = Self.dayFormatter.string(
                from: Date().addingTimeInterval(-(range.interval - 86400))
            )
            history = db.qualityDaily(sinceDay: since)
        } else {
            history = db.qualitySamples(since: Date().addingTimeInterval(-range.interval))
        }
    }

    // MARK: - Quality score + latency (combined row)

    private var qualityAndLatency: some View {
        HStack(alignment: .top, spacing: 16) {
            // Left column: quality score ring + level.
            HStack(spacing: 14) {
                ZStack {
                    Circle().stroke(Theme.bg3, lineWidth: 7).frame(width: 64, height: 64)
                    Circle()
                        .trim(from: 0, to: vm.qualityScore / 100)
                        .stroke(vm.qualityLevel.color, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 64, height: 64)
                        .animation(.snappy(duration: 0.4), value: vm.qualityScore)
                    Text("\(Int(vm.qualityScore))")
                        .font(.system(size: 22, weight: .bold, design: .rounded)).monospacedDigit()
                        .contentTransition(.numericText())
                        .animation(.snappy(duration: 0.4), value: Int(vm.qualityScore))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Quality").font(.caption).foregroundStyle(.secondary)
                    Text(vm.qualityLevel.rawValue)
                        .font(.title3).fontWeight(.semibold)
                        .foregroundStyle(vm.qualityLevel.color)
                }
            }

            Spacer()

            // Right column: latency, aligned to the trailing edge.
            VStack(alignment: .trailing, spacing: 6) {
                Text("Latency").font(.caption).foregroundStyle(.secondary)
                latencyRow(vm.internetLatency)
                latencyRow(vm.gatewayLatency)
            }
        }
    }

    @ViewBuilder private func latencyRow(_ m: LatencyMetrics?) -> some View {
        if let m {
            HStack(spacing: 6) {
                Text(m.label).foregroundStyle(.secondary)
                if m.reachable {
                    Text("\(Int(m.avgMs)) ms")
                        .foregroundStyle(latencyColor(m.avgMs)).monospacedDigit().fontWeight(.semibold)
                        .contentTransition(.numericText())
                        .animation(.snappy(duration: 0.3), value: Int(m.avgMs))
                    if m.lossPct > 0 {
                        Text("loss \(Int(m.lossPct))%")
                            .font(.caption2).foregroundStyle(Theme.red).monospacedDigit()
                    }
                    Text("jitter \(Int(m.jitterMs))")
                        .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                        .contentTransition(.numericText())
                        .animation(.snappy(duration: 0.3), value: Int(m.jitterMs))
                } else {
                    Text("unreachable").foregroundStyle(Theme.red)
                }
            }
            .font(.subheadline)
        } else {
            Text("—").foregroundStyle(.secondary).font(.subheadline)
        }
    }

    /// Green/yellow/red by absolute latency, matching the quality palette feel.
    private func latencyColor(_ ms: Double) -> Color {
        switch ms {
        case ..<40: return Theme.green
        case ..<100: return Theme.aqua
        case ..<150: return Theme.yellow
        default: return Theme.red
        }
    }

    // MARK: - Connection details

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Connection").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Image(systemName: connectionSymbol)
                Text(vm.connection.rawValue)
                Spacer()
                if vm.vpnActive {
                    Label("VPN", systemImage: "lock.shield.fill")
                        .font(.caption).padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Theme.vpn.opacity(0.2), in: Capsule())
                        .foregroundStyle(Theme.vpn)
                }
            }
            .font(.callout)
            if vm.vpnActive, !vm.vpnInterfaces.isEmpty {
                Text(
                    "Tunnel interface\(vm.vpnInterfaces.count > 1 ? "s" : ""): \(vm.vpnInterfaces.joined(separator: ", "))"
                )
                .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private var connectionSymbol: String {
        switch vm.connection {
        case .wifi: return "wifi"
        case .ethernet: return "cable.connector"
        case .cellular: return "antenna.radiowaves.left.and.right"
        case .none: return "wifi.slash"
        case .other: return "network"
        }
    }

    // MARK: - Per-interface live usage

    private var interfacesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Interfaces (live)").font(.caption).foregroundStyle(.secondary)
            if vm.perInterface.isEmpty {
                Text("—").font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(vm.perInterface) { i in
                    HStack {
                        Text(i.name).frame(width: 70, alignment: .leading)
                        Spacer()
                        Text("↓ \(Fmt.rate(i.rxRate))").foregroundStyle(Theme.download).monospacedDigit()
                            .contentTransition(.numericText()).animation(
                                .snappy(duration: 0.3),
                                value: i.rxRate
                            )
                        Text("↑ \(Fmt.rate(i.txRate))").foregroundStyle(Theme.upload).monospacedDigit()
                            .contentTransition(.numericText()).animation(
                                .snappy(duration: 0.3),
                                value: i.txRate
                            )
                    }
                    .font(.callout)
                }
            }
        }
    }
}
