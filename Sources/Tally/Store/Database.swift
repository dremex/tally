import Foundation
import GRDB

/// Owns the SQLite connection, schema migrations, inserts, and the aggregate queries that back
/// the History and Apps tabs. DB lives in Application Support so it survives app restarts.
/// `Sendable` because its only stored state is GRDB's `DatabasePool`, which is itself thread-safe;
/// all reads/writes go through the pool's own serialization.
final class Database: Sendable {
    static let shared = try! Database()

    let pool: DatabasePool

    /// Raw fine-grained samples older than this are pruned; daily rollups are derived on demand
    /// from whatever raw rows remain, so totals stay accurate within the retention window.
    static let rawRetention: TimeInterval = 30 * 24 * 3600

    init() throws {
        let fm = FileManager.default
        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tally", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbURL = dir.appendingPathComponent("tally.sqlite")

        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
        }
        pool = try DatabasePool(path: dbURL.path, configuration: config)
        try migrator.migrate(pool)
        NSLog("Tally DB at \(dbURL.path)")
    }

    private var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.create(table: "throughput_sample") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("ts", .datetime).notNull().indexed()
                t.column("interface", .text).notNull()
                t.column("rxBytes", .integer).notNull()
                t.column("txBytes", .integer).notNull()
                t.column("rxRate", .double).notNull()
                t.column("txRate", .double).notNull()
            }
            try db.create(table: "app_sample") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("ts", .datetime).notNull().indexed()
                t.column("processName", .text).notNull()
                t.column("rxBytes", .integer).notNull()
                t.column("txBytes", .integer).notNull()
            }
        }
        // Per-app daily rollup. Never pruned, so Month/Total stay accurate forever even after
        // the raw app_sample rows expire at 30 days. `day` is the local calendar day (yyyy-MM-dd).
        m.registerMigration("v2") { db in
            try db.create(table: "app_daily") { t in
                t.column("day", .text).notNull()
                t.column("processName", .text).notNull()
                t.column("rxBytes", .integer).notNull()
                t.column("txBytes", .integer).notNull()
                t.primaryKey(["day", "processName"])
            }
        }
        // Connection-quality history. Raw 10s samples (pruned at 30 days) + a never-pruned daily
        // rollup keeping averages so full history survives, just coarser past 30 days.
        m.registerMigration("v3") { db in
            try db.create(table: "quality_sample") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("ts", .datetime).notNull().indexed()
                t.column("latencyMs", .double).notNull()
                t.column("jitterMs", .double).notNull()
                t.column("lossPct", .double).notNull()
                t.column("score", .double).notNull()
            }
            try db.create(table: "quality_daily") { t in
                t.column("day", .text).notNull().primaryKey()
                // Running sums + count to derive daily averages without storing every sample.
                t.column("sumLatency", .double).notNull()
                t.column("sumJitter", .double).notNull()
                t.column("sumLoss", .double).notNull()
                t.column("sumScore", .double).notNull()
                t.column("count", .integer).notNull()
                t.column("minScore", .double).notNull()
                t.column("maxLatency", .double).notNull()
            }
        }
        return m
    }

    // MARK: - Writes

    func insertThroughput(_ sample: ThroughputSample) {
        pool.asyncWrite { db in
            try sample.insert(db)
        } completion: { _, result in
            if case let .failure(err) = result { NSLog("throughput insert failed: \(err)") }
        }
    }

    /// Persist a quality sample and fold it into the never-pruned daily rollup (running sums so
    /// daily averages survive after the raw rows expire).
    func insertQuality(_ sample: QualitySample) {
        pool.asyncWrite { db in
            try sample.insert(db)
            try db.execute(sql: """
            INSERT INTO quality_daily (day, sumLatency, sumJitter, sumLoss, sumScore, count, minScore, maxLatency)
            VALUES (date(?, 'localtime'), ?, ?, ?, ?, 1, ?, ?)
            ON CONFLICT(day) DO UPDATE SET
                sumLatency = sumLatency + excluded.sumLatency,
                sumJitter  = sumJitter  + excluded.sumJitter,
                sumLoss    = sumLoss    + excluded.sumLoss,
                sumScore   = sumScore   + excluded.sumScore,
                count      = count + 1,
                minScore   = min(minScore, excluded.minScore),
                maxLatency = max(maxLatency, excluded.maxLatency)
            """, arguments: [
                sample.ts,
                sample.latencyMs,
                sample.jitterMs,
                sample.lossPct,
                sample.score,
                sample.score,
                sample.latencyMs
            ])
        } completion: { _, result in
            if case let .failure(err) = result { NSLog("quality insert failed: \(err)") }
        }
    }

    func insertAppSamples(_ samples: [AppSample]) {
        guard !samples.isEmpty else { return }
        pool.asyncWrite { db in
            for s in samples {
                try s.insert(db)
                // Accumulate into the never-pruned daily rollup (keyed by local day + process).
                try db.execute(sql: """
                INSERT INTO app_daily (day, processName, rxBytes, txBytes)
                VALUES (date(?, 'localtime'), ?, ?, ?)
                ON CONFLICT(day, processName) DO UPDATE SET
                    rxBytes = rxBytes + excluded.rxBytes,
                    txBytes = txBytes + excluded.txBytes
                """, arguments: [s.ts, s.processName, s.rxBytes, s.txBytes])
            }
        } completion: { _, result in
            if case let .failure(err) = result { NSLog("app insert failed: \(err)") }
        }
    }

    // MARK: - Reads (History tab)

    /// Throughput samples within [since, now], oldest first — for the history chart.
    func throughputSamples(since: Date) -> [ThroughputSample] {
        (try? pool.read { db in
            try ThroughputSample
                .filter(ThroughputSample.Columns.ts >= since)
                .order(ThroughputSample.Columns.ts.asc)
                .fetchAll(db)
        }) ?? []
    }

    /// Summed bytes over a window — for the "today" / "this month" total figures.
    func totalBytes(since: Date) -> (rx: Int64, tx: Int64) {
        let row = try? pool.read { db in
            try Row.fetchOne(db, sql: """
            SELECT COALESCE(SUM(rxBytes),0) AS rx, COALESCE(SUM(txBytes),0) AS tx
            FROM throughput_sample WHERE ts >= ?
            """, arguments: [since])
        }
        guard let row else { return (0, 0) }
        return (row["rx"], row["tx"])
    }

    /// Raw quality samples in [since, now], oldest first — for the Connection tab's Hour/Day graph.
    func qualitySamples(since: Date) -> [QualityPoint] {
        (try? pool.read { db in
            try QualitySample
                .filter(Column("ts") >= since)
                .order(Column("ts").asc)
                .fetchAll(db)
                .map { QualityPoint(time: $0.ts, latencyMs: $0.latencyMs, score: $0.score) }
        }) ?? []
    }

    /// Daily-average quality points from the never-pruned rollup, oldest first — for Week/Month.
    func qualityDaily(sinceDay: String) -> [QualityPoint] {
        (try? pool.read { db in
            try Row.fetchAll(db, sql: """
            SELECT day, sumLatency / count AS avgLatency, sumScore / count AS avgScore
            FROM quality_daily WHERE day >= ? ORDER BY day ASC
            """, arguments: [sinceDay])
                .compactMap { row -> QualityPoint? in
                    let day: String = row["day"]
                    let fmt = DateFormatter()
                    fmt.dateFormat = "yyyy-MM-dd"
                    guard let date = fmt.date(from: day) else { return nil }
                    return QualityPoint(time: date, latencyMs: row["avgLatency"], score: row["avgScore"])
                }
        }) ?? []
    }

    /// Highest download/upload rate ever recorded (bytes/sec), from the aggregated throughput rows.
    func peakRates() -> (rx: Double, tx: Double) {
        let row = try? pool.read { db in
            try Row.fetchOne(db, sql: """
            SELECT COALESCE(MAX(rxRate),0) AS rx, COALESCE(MAX(txRate),0) AS tx
            FROM throughput_sample
            """)
        }
        guard let row else { return (0, 0) }
        return (row["rx"], row["tx"])
    }

    /// Per-day totals (across all apps) from the never-pruned rollup, most recent `limit` days,
    /// returned oldest-first for charting. Powers the daily chart, averages, and busiest-day stat.
    func dailyTotals(limit: Int = 30) -> [DailyTotal] {
        (try? pool.read { db in
            let rows = try DailyTotal.fetchAll(db, sql: """
            SELECT day,
                   COALESCE(SUM(rxBytes),0) AS rxBytes,
                   COALESCE(SUM(txBytes),0) AS txBytes
            FROM app_daily
            GROUP BY day
            ORDER BY day DESC
            LIMIT ?
            """, arguments: [limit])
            return rows.reversed() // oldest-first for the chart
        }) ?? []
    }

    /// All-time total bytes across every app/day in the never-pruned rollup.
    func allTimeBytes() -> (rx: Int64, tx: Int64) {
        let row = try? pool.read { db in
            try Row.fetchOne(db, sql: """
            SELECT COALESCE(SUM(rxBytes),0) AS rx, COALESCE(SUM(txBytes),0) AS tx FROM app_daily
            """)
        }
        guard let row else { return (0, 0) }
        return (row["rx"], row["tx"])
    }

    /// Number of distinct days with recorded usage, and the earliest day string (nil if none).
    func trackingSince() -> (days: Int, earliest: String?) {
        let row = try? pool.read { db in
            try Row.fetchOne(db, sql: """
            SELECT COUNT(DISTINCT day) AS days, MIN(day) AS earliest FROM app_daily
            """)
        }
        guard let row else { return (0, nil) }
        return (row["days"], row["earliest"])
    }

    /// Apps that were transferring around a given instant — for the graph hover interaction.
    /// Sums raw per-app samples within ±`window` seconds of `time`, biggest first.
    func appsActive(around time: Date, window: TimeInterval = 5) -> [AppUsage] {
        let lo = time.addingTimeInterval(-window)
        let hi = time.addingTimeInterval(window)
        return (try? pool.read { db in
            try AppUsage.fetchAll(db, sql: """
            SELECT processName,
                   COALESCE(SUM(rxBytes),0) AS rxBytes,
                   COALESCE(SUM(txBytes),0) AS txBytes
            FROM app_sample WHERE ts >= ? AND ts <= ?
            GROUP BY processName
            ORDER BY (SUM(rxBytes)+SUM(txBytes)) DESC
            """, arguments: [lo, hi])
        }) ?? []
    }

    /// One app's per-sample usage over a window — for overlaying its contribution on the graph
    /// when you hover its row. Returns (timestamp, rxBytes, txBytes) per raw sample, oldest first.
    func appTimeline(process: String, since: Date) -> [(ts: Date, rx: Int64, tx: Int64)] {
        (try? pool.read { db in
            try Row.fetchAll(db, sql: """
            SELECT ts, rxBytes, txBytes FROM app_sample
            WHERE processName = ? AND ts >= ?
            ORDER BY ts ASC
            """, arguments: [process, since])
                .map { (ts: $0["ts"], rx: $0["rxBytes"], tx: $0["txBytes"]) }
        }) ?? []
    }

    // MARK: - Reads (Apps tab)

    /// Per-app summed usage over a window, biggest first — for the Apps "range" view.
    func appUsage(since: Date, limit: Int = 50) -> [AppUsage] {
        (try? pool.read { db in
            try AppUsage.fetchAll(db, sql: """
            SELECT processName,
                   COALESCE(SUM(rxBytes),0) AS rxBytes,
                   COALESCE(SUM(txBytes),0) AS txBytes
            FROM app_sample WHERE ts >= ?
            GROUP BY processName
            ORDER BY (SUM(rxBytes)+SUM(txBytes)) DESC
            LIMIT ?
            """, arguments: [since, limit])
        }) ?? []
    }

    /// Per-app usage from the never-pruned daily rollup, biggest first. `sinceDay` is an inclusive
    /// local day string (yyyy-MM-dd); pass nil for all-time totals.
    func appUsageDaily(sinceDay: String?, limit: Int = 50) -> [AppUsage] {
        (try? pool.read { db in
            let whereClause = sinceDay == nil ? "" : "WHERE day >= ?"
            let args: StatementArguments = sinceDay == nil ? [limit] : [sinceDay, limit]
            return try AppUsage.fetchAll(db, sql: """
            SELECT processName,
                   COALESCE(SUM(rxBytes),0) AS rxBytes,
                   COALESCE(SUM(txBytes),0) AS txBytes
            FROM app_daily \(whereClause)
            GROUP BY processName
            ORDER BY (SUM(rxBytes)+SUM(txBytes)) DESC
            LIMIT ?
            """, arguments: args)
        }) ?? []
    }

    // MARK: - Maintenance

    func pruneOldData() {
        let cutoff = Date().addingTimeInterval(-Self.rawRetention)
        pool.asyncWrite { db in
            try db.execute(sql: "DELETE FROM throughput_sample WHERE ts < ?", arguments: [cutoff])
            try db.execute(sql: "DELETE FROM app_sample WHERE ts < ?", arguments: [cutoff])
            try db.execute(sql: "DELETE FROM quality_sample WHERE ts < ?", arguments: [cutoff])
        } completion: { _, result in
            if case let .failure(err) = result { NSLog("prune failed: \(err)") }
        }
    }
}
