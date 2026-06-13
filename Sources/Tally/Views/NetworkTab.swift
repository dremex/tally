import Charts
import SwiftUI

/// Combined view: a single range selector drives the throughput graph AND the per-app list below
/// it, so you see both "how much" and "which apps" for the same period.
///
/// Data sources per range:
///  - .live           → in-memory points (per-second) + current live per-app rates
///  - .hour / .day    → DB throughput samples + today's per-app rollup
///  - .week / .month  → DB throughput samples + that window's per-app rollup
struct NetworkTab: View {
    enum Range: String, CaseIterable, Identifiable {
        case live = "Live", hour = "Hour", day = "Day", week = "Week", month = "Month"
        var id: String {
            rawValue
        }

        /// History window in seconds (nil for the live in-memory view).
        var interval: TimeInterval? {
            switch self {
            case .live: return nil
            case .hour: return 3600
            case .day: return 86400
            case .week: return 7 * 86400
            case .month: return 30 * 86400
            }
        }
    }

    @EnvironmentObject var vm: NetworkViewModel
    @State private var range: Range = .live

    // History graph state.
    @State private var samples: [ThroughputSample] = []
    @State private var domainStart = Date()
    @State private var domainEnd = Date()
    @State private var periodTotal: (rx: Int64, tx: Int64) = (0, 0)

    /// Per-app list for non-live ranges (from the daily rollup).
    @State private var rangeUsage: [AppUsage] = []

    private let db = Database.shared
    private let refresh = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    @State private var tick = 0
    @State private var drained = false // refresh-bar animation state (full → empty per interval)

    // Graph hover: the time under the cursor, and the apps active in that window (highlighted below).
    @State private var hoverTime: Date?
    @State private var hoverApps: Set<String> = []
    @State private var hoverTopApp: String?

    // Row hover (inverse): the app whose row is hovered, and its usage overlaid on the graph.
    @State private var hoverApp: String?
    @State private var hoverAppPoints: [RatePoint] = []

    private static let dayFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Range", selection: $range) {
                ForEach(Range.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            header
            graph.frame(height: 120)
            if range != .live { totalsStrip }
            Divider()
            appsHeader
            appList
        }
        .padding()
        .onAppear(perform: reload)
        .onChange(of: range) { _, _ in reload() }
        .onReceive(refresh) { _ in
            tick += 1
            // Live & Hour track the moving edge each second; coarser ranges every 5s is plenty.
            if range == .live || range == .hour || tick % 5 == 0 { reload() }
        }
    }

    // MARK: - Header (current rates + connection)

    private var header: some View {
        HStack(spacing: 20) {
            rateBlock(title: "Download", rate: vm.rxRate, color: Theme.download, symbol: "arrow.down")
            rateBlock(title: "Upload", rate: vm.txRate, color: Theme.upload, symbol: "arrow.up")
            Spacer()
            HStack(spacing: 5) {
                Image(systemName: connectionSymbol)
                Text(vm.connection.rawValue)
            }
            .font(.callout).foregroundStyle(.secondary)
        }
    }

    private func rateBlock(title: String, rate: Double, color: Color, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Label(title, systemImage: symbol)
                .font(.caption2).foregroundStyle(.secondary)
            Text(Fmt.rate(rate))
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundStyle(color).monospacedDigit()
            // No numericText animation here: these rates change every second, so a 0.3s roll never
            // settles before the next value arrives — it pins CoreAnimation at 60fps continuously.
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

    // MARK: - Graph

    /// Points to plot. Live: in-memory sparkline. History: DB samples, with the live in-memory tail
    /// merged in for Hour so the right edge tracks "now" between 10s flushes.
    private var points: [RatePoint] {
        if range == .live {
            return vm.recent
        }
        var pts = samples.map { RatePoint(time: $0.ts, rxRate: $0.rxRate, txRate: $0.txRate) }
        if range == .hour {
            let lastPersisted = samples.last?.ts ?? .distantPast
            pts += vm.recent.filter { $0.time > lastPersisted }
        }
        return pts
    }

    @ViewBuilder private var graph: some View {
        let pts = points
        if pts.isEmpty {
            RoundedRectangle(cornerRadius: 6).fill(Theme.bg2)
                .overlay(Text(range == .live ? "Collecting…" : "No history yet — leave Tally running.")
                    .font(.caption).foregroundStyle(.secondary))
        } else {
            Chart {
                ForEach(pts) { p in
                    AreaMark(x: .value("Time", p.time), y: .value("Down", p.rxRate))
                        .foregroundStyle(Theme.download.opacity(0.25))
                    LineMark(
                        x: .value("Time", p.time),
                        y: .value("Down", p.rxRate),
                        series: .value("s", "down")
                    ).foregroundStyle(Theme.download)
                    LineMark(
                        x: .value("Time", p.time),
                        y: .value("Up", p.txRate),
                        series: .value("s", "up")
                    ).foregroundStyle(Theme.upload)
                }
                if let hoverTime {
                    RuleMark(x: .value("Hover", hoverTime))
                        .foregroundStyle(Theme.fg.opacity(0.5))
                        .annotation(
                            position: .top,
                            alignment: .center,
                            overflowResolution: .init(x: .fit, y: .disabled)
                        ) {
                            hoverAnnotation
                        }
                }
                // Inverse hover: overlay the hovered app's own usage on top of the total graph.
                ForEach(hoverAppPoints) { p in
                    AreaMark(
                        x: .value("Time", p.time),
                        y: .value("App", p.rxRate + p.txRate),
                        series: .value("s", "app")
                    )
                    .foregroundStyle(Theme.yellow.opacity(0.35))
                    LineMark(
                        x: .value("Time", p.time),
                        y: .value("App", p.rxRate + p.txRate),
                        series: .value("s", "app")
                    )
                    .foregroundStyle(Theme.yellow)
                }
            }
            .chartYAxis {
                AxisMarks { value in
                    AxisValueLabel { if let v = value.as(Double.self) { Text(Fmt.rate(v)) } }
                }
            }
            // Live auto-scales the x-axis; history pins it to the full window so ranges differ visibly.
            .chartXScale(domain: range == .live ? automaticDomain : domainStart...domainEnd)
            .chartXAxis(range == .live ? .hidden : .automatic)
            .chartXSelection(value: $hoverTime)
            .onChange(of: hoverTime) { _, t in updateHover(t) }
        }
    }

    /// Small tooltip shown above the hover line: the time and the top app active then.
    @ViewBuilder private var hoverAnnotation: some View {
        if let hoverTime {
            VStack(spacing: 1) {
                Text(hoverTime, format: .dateTime.hour().minute().second())
                    .font(.caption2).foregroundStyle(.secondary)
                if let top = hoverTopApp {
                    Text(top).font(.caption2.bold()).foregroundStyle(Theme.aqua)
                } else {
                    Text("no app data").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 5))
        }
    }

    /// On hover, find which apps were transferring in that ~10s window and remember them so the
    /// list below can highlight matches. Querying raw app_sample → only meaningful for Hour/Day
    /// (and Live), where 5s-granular per-app rows exist within retention.
    private func updateHover(_ t: Date?) {
        guard let t, range != .week, range != .month else {
            hoverApps = []
            hoverTopApp = nil
            return
        }
        let active = db.appsActive(around: t, window: 5)
        hoverApps = Set(active.map(\.processName))
        hoverTopApp = active.first?.processName
    }

    /// For the live view, let Charts fit the data automatically (closed range required by the API,
    /// so fall back to the recent points' span).
    private var automaticDomain: ClosedRange<Date> {
        let times = vm.recent.map(\.time)
        let lo = times.min() ?? Date()
        let hi = times.max() ?? Date()
        return lo <= hi ? lo...hi : lo...lo.addingTimeInterval(1)
    }

    // MARK: - Period totals

    /// Big, easy-to-read total usage for the selected window, summed from the throughput samples.
    private var totalsStrip: some View {
        HStack(spacing: 0) {
            totalCell(label: "Downloaded", value: periodTotal.rx, color: Theme.download)
            Divider().frame(height: 34)
            totalCell(label: "Uploaded", value: periodTotal.tx, color: Theme.upload)
            Divider().frame(height: 34)
            totalCell(label: "Total", value: periodTotal.rx + periodTotal.tx, color: Theme.primaryText)
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 8))
    }

    private func totalCell(label: String, value: Int64, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(Fmt.bytes(value))
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(color).monospacedDigit()
                .contentTransition(.numericText())
                .animation(.snappy(duration: 0.3), value: value)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - App list

    private var appsHeader: some View {
        HStack(spacing: 8) {
            Text(appsTitle).font(.caption).foregroundStyle(.secondary)
            if range == .live { refreshBar }
        }
    }

    /// Thin hairline that drains smoothly over the nettop refresh interval and snaps full on each
    /// refresh, so you can see how soon the live app list will next update.
    private var refreshBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.bg2)
                Capsule().fill(Theme.aqua.opacity(0.7))
                    .frame(width: geo.size.width * (drained ? 0 : 1))
            }
        }
        .frame(height: 3)
        .frame(maxWidth: 80)
        // On each refresh: jump to full instantly, then animate down to empty over the interval.
        .onChange(of: vm.lastAppRefresh) { _, _ in
            drained = false
            withAnimation(.linear(duration: vm.appRefreshInterval)) { drained = true }
        }
    }

    private var appsTitle: String {
        switch range {
        case .live: return "Apps now"
        case .hour, .day: return "Apps today"
        case .week: return "Apps this week"
        case .month: return "Apps this month"
        }
    }

    @ViewBuilder private var appList: some View {
        if range == .live {
            if vm.appReadings.isEmpty {
                placeholder("Waiting for the first nettop sample…")
            } else {
                // Plain ScrollView (not List) so per-row .onHover fires reliably on macOS.
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(vm.appReadings) { r in
                            appRow(
                                name: r.processName,
                                primary: Fmt.rate(r.totalRate),
                                down: "↓ \(Fmt.rate(r.rxRate))",
                                up: "↑ \(Fmt.rate(r.txRate))"
                            )
                        }
                    }
                }
            }
        } else {
            if rangeUsage.isEmpty {
                placeholder("No usage recorded for this range yet.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(rangeUsage) { u in
                            appRow(
                                name: u.processName,
                                primary: Fmt.bytes(u.totalBytes),
                                down: "↓ \(Fmt.bytes(u.rxBytes))",
                                up: "↑ \(Fmt.bytes(u.txBytes))"
                            )
                        }
                    }
                }
            }
        }
    }

    private func appRow(name: String, primary: String, down: String, up: String) -> some View {
        // When hovering the graph, highlight apps active at that time; dim the rest.
        let hovering = hoverTime != nil && !hoverApps.isEmpty
        let isActive = hoverApps.contains(name)
        return HStack(spacing: 10) {
            Image(nsImage: AppIconProvider.shared.icon(for: name))
                .resizable().frame(width: 20, height: 20)
            Text(name).lineLimit(1)
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                // Live app rates refresh every ~5s and re-sort; skip the per-value roll animation
                // (it restarts on every refresh and keeps the layer tree redrawing).
                Text(primary).monospacedDigit()
                HStack(spacing: 6) {
                    Text(down).foregroundStyle(Theme.download)
                    Text(up).foregroundStyle(Theme.upload)
                }
                .font(.caption2).monospacedDigit()
            }
        }
        .padding(.vertical, 5).padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(rowBackground(name: name, hovering: hovering, isActive: isActive))
        )
        .opacity(hovering && !isActive ? 0.4 : 1)
        .contentShape(Rectangle())
        .onHover { inside in hoverRow(name: name, inside: inside) }
        .animation(.easeOut(duration: 0.15), value: hovering && isActive)
    }

    private func rowBackground(name: String, hovering: Bool, isActive: Bool) -> Color {
        if name ==
            hoverApp { return Theme.yellow.opacity(0.18) } // inverse-hover: this row drives the overlay
        if hovering, isActive { return Theme.aqua.opacity(0.18) } // graph-hover highlight
        return .clear
    }

    /// On row hover, overlay that app's usage on the graph; on exit, clear it. Only meaningful where
    /// raw per-app samples exist for the window (Live/Hour/Day) — Week/Month skip it.
    private func hoverRow(name: String, inside: Bool) {
        guard inside else {
            if hoverApp == name { hoverApp = nil
                hoverAppPoints = []
            }
            return
        }
        hoverApp = name
        guard range != .week, range != .month else { hoverAppPoints = []
            return
        }
        let since = range == .live
            ? (vm.recent.first?.time ?? Date().addingTimeInterval(-300))
            : domainStart
        let window = vm.appRefreshInterval // app_sample bytes are per ~5s window → divide for a rate
        hoverAppPoints = db.appTimeline(process: name, since: since).map {
            RatePoint(time: $0.ts, rxRate: Double($0.rx) / window, txRate: Double($0.tx) / window)
        }
    }

    private func placeholder(_ text: String) -> some View {
        VStack { Spacer()
            Text(text).font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, minHeight: 80)
    }

    // MARK: - Data loading

    private func reload() {
        guard range != .live else { return } // live data is pushed by the view model
        let now = Date()
        guard let interval = range.interval else { return }
        domainStart = now.addingTimeInterval(-interval)
        domainEnd = now
        samples = db.throughputSamples(since: domainStart)
        periodTotal = (samples.reduce(0) { $0 + $1.rxBytes }, samples.reduce(0) { $0 + $1.txBytes })

        let cal = Calendar.current
        let sinceDay: String
        switch range {
        case .hour, .day: sinceDay = Self.dayFormatter.string(from: cal.startOfDay(for: now))
        case .week: sinceDay = Self.dayFormatter.string(from: now.addingTimeInterval(-6 * 86400))
        case .month: sinceDay = Self.dayFormatter.string(from: now.addingTimeInterval(-29 * 86400))
        case .live: return
        }
        rangeUsage = db.appUsageDaily(sinceDay: sinceDay)
    }
}
