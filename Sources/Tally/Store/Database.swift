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

    // MARK: - Async reads (off the main thread)

    /// Snapshot of everything the Network history view needs for one range, fetched in a single
    /// off-thread read. `completion` is called on the main queue.
    struct HistorySnapshot {
        var samples: [ThroughputSample]
        var periodTotal: (rx: Int64, tx: Int64)
        var rangeUsage: [AppUsage]
    }

    /// Read throughput samples (and, when `sinceDay != nil`, the per-app rollup) without blocking
    /// the caller. When `includeUsage` is false the rollup query is skipped entirely — used by the
    /// per-second timer tick, which only needs the moving graph edge refreshed.
    ///
    /// `bucketSeconds`: when > 0, samples are downsampled into fixed time buckets in SQL — summing
    /// bytes and averaging rates per bucket. A month holds ~260K raw rows (one per 10s); fetching
    /// them all to draw a 120px chart is the bulk of the switch delay, so wide ranges bucket down to
    /// a few hundred rows. Totals are summed from the same buckets, so they stay exact regardless.
    func historySnapshot(
        since: Date,
        sinceDay: String?,
        includeUsage: Bool,
        bucketSeconds: Int = 0,
        completion: @escaping @MainActor (HistorySnapshot) -> Void
    ) {
        pool.asyncRead { dbResult in
            let snapshot: HistorySnapshot
            do {
                let db = try dbResult.get()
                let samples: [ThroughputSample] = if bucketSeconds > 0 {
                    try Self.bucketedSamples(db, since: since, bucketSeconds: bucketSeconds)
                } else {
                    try ThroughputSample
                        .filter(ThroughputSample.Columns.ts >= since)
                        .order(ThroughputSample.Columns.ts.asc)
                        .fetchAll(db)
                }
                let total = samples.reduce(into: (rx: Int64(0), tx: Int64(0))) {
                    $0.rx += $1.rxBytes
                    $0.tx += $1.txBytes
                }
                var usage: [AppUsage] = []
                if includeUsage, let sinceDay {
                    usage = try Self.appUsageRollup(db, sinceDay: sinceDay, limit: 50)
                }
                snapshot = HistorySnapshot(samples: samples, periodTotal: total, rangeUsage: usage)
            } catch {
                NSLog("historySnapshot read failed: \(error)")
                snapshot = HistorySnapshot(samples: [], periodTotal: (0, 0), rangeUsage: [])
            }
            let result = snapshot
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(result) } }
        }
    }

    // MARK: - Shared aggregate queries (used by the snapshot reads above)

    /// Per-app summed usage from the never-pruned daily rollup, biggest first. `sinceDay` (inclusive
    /// yyyy-MM-dd local) bounds the window; nil = all time.
    private static func appUsageRollup(
        _ db: GRDB.Database,
        sinceDay: String?,
        limit: Int
    ) throws -> [AppUsage] {
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
    }

    /// Summed rx/tx bytes from `table` where `ts >= since` (a `.datetime` column) — for window totals.
    private static func sumBytes(
        _ db: GRDB.Database,
        table: String,
        since: Date
    ) throws -> (rx: Int64, tx: Int64) {
        let row = try Row.fetchOne(db, sql: """
        SELECT COALESCE(SUM(rxBytes),0) AS rx, COALESCE(SUM(txBytes),0) AS tx
        FROM \(table) WHERE ts >= ?
        """, arguments: [since])
        return (row?["rx"] ?? 0, row?["tx"] ?? 0)
    }

    /// Downsample throughput rows into `bucketSeconds`-wide buckets: bytes summed, rates averaged,
    /// timestamp pinned to the bucket start. Cuts a month's ~260K rows down to a few hundred so the
    /// chart query returns fast. `ts` is stored as ISO text, so we bucket via strftime epoch.
    private static func bucketedSamples(
        _ db: GRDB.Database,
        since: Date,
        bucketSeconds: Int
    ) throws -> [ThroughputSample] {
        let rows = try Row.fetchAll(db, sql: """
        SELECT (CAST(strftime('%s', ts) AS INTEGER) / ?) * ? AS bucket,
               SUM(rxBytes) AS rxBytes,
               SUM(txBytes) AS txBytes,
               AVG(rxRate)  AS rxRate,
               AVG(txRate)  AS txRate
        FROM throughput_sample
        WHERE ts >= ?
        GROUP BY bucket
        ORDER BY bucket ASC
        """, arguments: [bucketSeconds, bucketSeconds, since])
        return rows.map { row in
            ThroughputSample(
                id: row["bucket"], // bucket epoch is a stable, unique id for the chart's ForEach
                ts: Date(timeIntervalSince1970: row["bucket"]),
                interface: "",
                rxBytes: row["rxBytes"],
                txBytes: row["txBytes"],
                rxRate: row["rxRate"],
                txRate: row["txRate"]
            )
        }
    }

    /// Everything the Stats tab shows, read in a single off-thread pass. `completion` runs on main.
    /// Today/week/month/peak come from the interface-level `throughput_sample` (so the headline
    /// numbers capture *all* traffic, including unattributed system traffic nettop can't tie to a
    /// process); all-time, the daily chart, tracking span, and top apps come from the never-pruned
    /// `app_daily` rollup (throughput_sample only retains 30 days). All run off the main thread.
    struct StatsSnapshot {
        var today: (rx: Int64, tx: Int64) = (0, 0)
        var week: (rx: Int64, tx: Int64) = (0, 0)
        var month: (rx: Int64, tx: Int64) = (0, 0)
        var allTime: (rx: Int64, tx: Int64) = (0, 0)
        var peak: (rx: Double, tx: Double) = (0, 0)
        var daily: [DailyTotal] = []
        var trackedDays = 0
        var earliestDay: String?
        var topApps: [AppUsage] = []
    }

    func statsSnapshot(
        todayStart: Date,
        weekStart: Date,
        monthStart: Date,
        completion: @escaping @MainActor (StatsSnapshot) -> Void
    ) {
        pool.asyncRead { dbResult in
            var snap = StatsSnapshot()
            do {
                let db = try dbResult.get()

                // Window totals from the raw interface counter — a SUM over the indexed ts range,
                // fast even at 30-days-of-10s-rows scale, and now off the main thread.
                snap.today = try Self.sumBytes(db, table: "throughput_sample", since: todayStart)
                snap.week = try Self.sumBytes(db, table: "throughput_sample", since: weekStart)
                snap.month = try Self.sumBytes(db, table: "throughput_sample", since: monthStart)

                // throughput_sample only retains 30 days, so all-time must come from the rollup.
                if let row = try Row.fetchOne(
                    db,
                    sql:
                    "SELECT COALESCE(SUM(rxBytes),0) AS rx, COALESCE(SUM(txBytes),0) AS tx FROM app_daily"
                ) {
                    snap.allTime = (row["rx"], row["tx"])
                }

                if let row = try Row.fetchOne(
                    db,
                    sql:
                    "SELECT COALESCE(MAX(rxRate),0) AS rx, COALESCE(MAX(txRate),0) AS tx FROM throughput_sample"
                ) {
                    snap.peak = (row["rx"], row["tx"])
                }

                snap.daily = try DailyTotal.fetchAll(db, sql: """
                SELECT day,
                       COALESCE(SUM(rxBytes),0) AS rxBytes,
                       COALESCE(SUM(txBytes),0) AS txBytes
                FROM app_daily GROUP BY day ORDER BY day DESC LIMIT 30
                """).reversed()

                if let row = try Row.fetchOne(
                    db,
                    sql:
                    "SELECT COUNT(DISTINCT day) AS days, MIN(day) AS earliest FROM app_daily"
                ) {
                    snap.trackedDays = row["days"]
                    snap.earliestDay = row["earliest"]
                }

                snap.topApps = try Self.appUsageRollup(db, sinceDay: nil, limit: 8)
            } catch {
                NSLog("statsSnapshot read failed: \(error)")
            }
            let result = snap
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(result) } }
        }
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
