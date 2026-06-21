import Charts
import SwiftUI

/// Overview tab: at-a-glance totals, a daily-usage chart, peak/average figures, how long Tally has
/// been tracking, and the all-time top apps. All data comes from the never-pruned daily rollup
/// (plus peak rates from throughput_sample), so these figures persist for the life of the install.
struct StatsTab: View {
    @State private var today: (rx: Int64, tx: Int64) = (0, 0)
    @State private var week: (rx: Int64, tx: Int64) = (0, 0)
    @State private var month: (rx: Int64, tx: Int64) = (0, 0)
    @State private var allTime: (rx: Int64, tx: Int64) = (0, 0)
    @State private var peak: (rx: Double, tx: Double) = (0, 0)
    @State private var daily: [DailyTotal] = []
    @State private var trackedDays = 0
    @State private var earliestDay: String?
    @State private var topApps: [AppUsage] = []
    /// False until the first off-thread snapshot lands — drives skeletons on initial open.
    @State private var loaded = false
    /// Discards a superseded in-flight read so it can't clobber newer data.
    @State private var gate = LoadGate()

    private let db = Database.shared
    private let refresh = Timer.publish(every: 10, on: .main, in: .common).autoconnect()

    /// Matches the rollup's day keys (yyyy-MM-dd, local) for backfilling missing days.
    private static let dayFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt
    }()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if loaded {
                    totalsGrid
                    dailyChartSection
                    peakAveragesSection
                    topAppsSection
                } else {
                    statsSkeleton
                }
            }
            .padding()
        }
        .onAppear(perform: reload)
        .onReceive(refresh) { _ in reload() }
    }

    // MARK: - Totals grid

    private var totalsGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            totalCard("Today", today)
            totalCard("This week", week)
            totalCard("This month", month)
            totalCard("All time", allTime)
        }
    }

    private func totalCard(_ title: String, _ b: (rx: Int64, tx: Int64)) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(Fmt.bytes(b.rx + b.tx))
                .font(.system(size: 19, weight: .semibold, design: .rounded)).monospacedDigit()
                .contentTransition(.numericText())
                .animation(.snappy(duration: 0.3), value: b.rx + b.tx)
            HStack(spacing: 8) {
                Text("↓ \(Fmt.bytes(b.rx))").foregroundStyle(Theme.download)
                    .contentTransition(.numericText()).animation(.snappy(duration: 0.3), value: b.rx)
                Text("↑ \(Fmt.bytes(b.tx))").foregroundStyle(Theme.upload)
                    .contentTransition(.numericText()).animation(.snappy(duration: 0.3), value: b.tx)
            }
            .font(.caption2).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Daily chart

    private var dailyChartSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Daily usage (last 30 days)").font(.caption).foregroundStyle(.secondary)
            if daily.isEmpty {
                RoundedRectangle(cornerRadius: 6).fill(Theme.bg2)
                    .frame(height: 120)
                    .overlay(Text("No history yet.").font(.caption).foregroundStyle(.secondary))
            } else {
                Chart(daily) { d in
                    // X as a real Date (per day) so Charts gives a proper time axis that thins to
                    // a few labels, instead of one discrete label per day overlapping into garbage.
                    BarMark(x: .value("Day", date(for: d), unit: .day), y: .value("Down", d.rxBytes))
                        .foregroundStyle(Theme.download)
                    BarMark(x: .value("Day", date(for: d), unit: .day), y: .value("Up", d.txBytes))
                        .foregroundStyle(Theme.upload)
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day, count: 7)) { _ in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                    }
                }
                .chartYAxis {
                    AxisMarks { value in
                        AxisValueLabel { if let v = value.as(Double.self) { Text(Fmt.bytes(v)) } }
                    }
                }
                .frame(height: 120)
            }
        }
    }

    /// Parse a rollup day key ("2026-06-11") to a Date for the time axis; falls back to now.
    private func date(for d: DailyTotal) -> Date {
        Self.dayFormatter.date(from: d.day) ?? Date()
    }

    // MARK: - Peak & averages

    private var peakAveragesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            statRow("Peak download", Fmt.rate(peak.rx), Theme.download)
            statRow("Peak upload", Fmt.rate(peak.tx), Theme.upload)
            statRow("Daily average", Fmt.bytes(dailyAverage), Theme.primaryText)
            if let busiest {
                statRow("Busiest day", "\(busiest.day) · \(Fmt.bytes(busiest.totalBytes))", Theme.primaryText)
            }
            statRow("Tracking since", trackingLabel, .secondary)
        }
    }

    private func statRow(_ label: String, _ value: String, _ color: Color) -> some View {
        HStack {
            Text(label).font(.callout).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.callout).foregroundStyle(color).monospacedDigit()
                .contentTransition(.numericText())
                .animation(.snappy(duration: 0.3), value: value)
        }
    }

    private var dailyAverage: Double {
        guard !daily.isEmpty else { return 0 }
        let sum = daily.reduce(0) { $0 + $1.totalBytes }
        return Double(sum) / Double(daily.count)
    }

    private var busiest: DailyTotal? {
        daily.max { $0.totalBytes < $1.totalBytes }
    }

    private var trackingLabel: String {
        guard let earliestDay else { return "—" }
        return "\(earliestDay) (\(trackedDays) day\(trackedDays == 1 ? "" : "s"))"
    }

    // MARK: - Top apps (all time)

    private var topAppsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Top apps · all time").font(.caption).foregroundStyle(.secondary)
            if topApps.isEmpty {
                Text("No data yet.").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(topApps.prefix(8)) { u in
                    HStack(spacing: 10) {
                        Image(nsImage: AppIconProvider.shared.icon(for: u.processName))
                            .resizable().frame(width: 18, height: 18)
                        Text(u.processName).lineLimit(1)
                        Spacer()
                        Text(Fmt.bytes(u.totalBytes)).monospacedDigit()
                        Text("↓ \(Fmt.bytes(u.rxBytes))").font(.caption2).foregroundStyle(Theme.download)
                            .monospacedDigit()
                        Text("↑ \(Fmt.bytes(u.txBytes))").font(.caption2).foregroundStyle(Theme.upload)
                            .monospacedDigit()
                    }
                    .font(.callout)
                }
            }
        }
    }

    // MARK: - Skeleton (initial open, while the first read runs)

    private var statsSkeleton: some View {
        VStack(alignment: .leading, spacing: 14) {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(0..<4, id: \.self) { _ in
                    VStack(alignment: .leading, spacing: 6) {
                        SkeletonBar(width: 56, height: 9, cornerRadius: 3)
                        SkeletonBar(width: 84, height: 18)
                        SkeletonBar(width: 100, height: 8, cornerRadius: 3)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 8))
                }
            }
            SkeletonBar(width: 160, height: 9, cornerRadius: 3)
            SkeletonBar(height: 120, cornerRadius: 6)
            ForEach(0..<4, id: \.self) { _ in
                HStack {
                    SkeletonBar(width: 110, height: 11)
                    Spacer()
                    SkeletonBar(width: 70, height: 11)
                }
            }
        }
        .shimmer()
    }

    // MARK: - Load

    private func reload() {
        let cal = Calendar.current
        let now = Date()
        let todayStart = cal.startOfDay(for: now)
        let weekStart = now.addingTimeInterval(-6 * 86400)
        let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: now)) ?? now

        let token = gate.begin()
        db.statsSnapshot(
            todayStart: todayStart,
            weekStart: weekStart,
            monthStart: monthStart
        ) { snap in
            // Drop results from a refresh superseded by a newer one (cheap insurance against overlap).
            guard gate.isCurrent(token) else { return }
            today = snap.today
            week = snap.week
            month = snap.month
            allTime = snap.allTime
            peak = snap.peak
            daily = backfilledDaily(snap.daily, days: 30, now: now, cal: cal)
            trackedDays = snap.trackedDays
            earliestDay = snap.earliestDay
            topApps = snap.topApps
            loaded = true
        }
    }

    /// Pad the DB's daily rows out to a full `days`-long window ending today, filling any missing
    /// day with a zero entry — so the chart shows a continuous axis even with little history.
    private func backfilledDaily(_ rows: [DailyTotal], days: Int, now: Date, cal: Calendar) -> [DailyTotal] {
        let byDay = Dictionary(uniqueKeysWithValues: rows.map { ($0.day, $0) })
        let today = cal.startOfDay(for: now)
        return (0..<days).reversed().compactMap { offset -> DailyTotal? in
            guard let date = cal.date(byAdding: .day, value: -offset, to: today) else { return nil }
            let key = Self.dayFormatter.string(from: date)
            return byDay[key] ?? DailyTotal(day: key, rxBytes: 0, txBytes: 0)
        }
    }
}
