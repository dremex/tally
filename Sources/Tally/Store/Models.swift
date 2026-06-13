import Foundation
import GRDB

/// One aggregated throughput sample (totals across the active interface) persisted to SQLite.
/// `rxRate`/`txRate` are bytes/sec averaged over the aggregation window; the *_bytes fields are
/// the absolute bytes transferred during the window (used for accurate daily/monthly totals).
struct ThroughputSample: Codable, FetchableRecord, PersistableRecord, Identifiable {
    var id: Int64?
    var ts: Date
    var interface: String
    var rxBytes: Int64
    var txBytes: Int64
    var rxRate: Double
    var txRate: Double

    static let databaseTableName = "throughput_sample"

    enum Columns {
        static let ts = Column("ts")
        static let rxBytes = Column("rxBytes")
        static let txBytes = Column("txBytes")
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// Per-process network usage over one nettop sampling window.
struct AppSample: Codable, FetchableRecord, PersistableRecord, Identifiable {
    var id: Int64?
    var ts: Date
    var processName: String
    var rxBytes: Int64
    var txBytes: Int64

    static let databaseTableName = "app_sample"

    enum Columns {
        static let ts = Column("ts")
        static let processName = Column("processName")
        static let rxBytes = Column("rxBytes")
        static let txBytes = Column("txBytes")
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// Aggregate row for charts/tables (not a table — a query result).
struct UsageTotal: Codable, FetchableRecord {
    var rxBytes: Int64
    var txBytes: Int64
    var label: String?
}

/// Per-app rollup for the Apps tab "range" view.
struct AppUsage: Codable, FetchableRecord, Identifiable {
    var processName: String
    var rxBytes: Int64
    var txBytes: Int64
    var id: String {
        processName
    }

    var totalBytes: Int64 {
        rxBytes + txBytes
    }
}

/// One day's total usage across all apps — for the Stats tab's daily chart & averages.
struct DailyTotal: Codable, FetchableRecord, Identifiable {
    var day: String // yyyy-MM-dd (local)
    var rxBytes: Int64
    var txBytes: Int64
    var id: String {
        day
    }

    var totalBytes: Int64 {
        rxBytes + txBytes
    }
}

/// One raw connection-quality sample (~10s cadence) for the Connection tab's history graph.
struct QualitySample: Codable, FetchableRecord, PersistableRecord, Identifiable {
    var id: Int64?
    var ts: Date
    var latencyMs: Double
    var jitterMs: Double
    var lossPct: Double
    var score: Double
    static let databaseTableName = "quality_sample"
    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// A graphable quality point — used for both raw samples and daily-rollup averages.
struct QualityPoint: Identifiable {
    var time: Date
    var latencyMs: Double
    var score: Double
    var id: Date {
        time
    }
}
