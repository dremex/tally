import Foundation
import GRDB

/// Dumps the SQLite tables to CSV — one file per table — for analysis in Sheets, Claude, etc.
/// Reads straight from the schema (column names + values) so it stays correct if columns change.
enum DataExporter {
    /// Tables worth exporting: the raw samples plus the never-pruned daily rollups
    /// (which hold full history past the 30-day raw-retention window).
    static let tables = [
        "throughput_sample",
        "app_sample",
        "quality_sample",
        "app_daily",
        "quality_daily"
    ]

    /// Creates a timestamped `Tally-Export-<date>` subfolder inside `directory`, writes one
    /// `<table>.csv` per table into it, and returns the folder URL.
    /// Throws if the folder/DB read or any file write fails.
    @discardableResult
    static func exportCSV(to directory: URL, pool: DatabasePool = Database.shared.pool) throws -> URL {
        let folder = directory.appendingPathComponent(exportFolderName(), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for table in tables {
            let csv = try pool.read { db in try csvForTable(table, db) }
            let url = folder.appendingPathComponent("\(table).csv")
            try csv.write(to: url, atomically: true, encoding: .utf8)
        }
        return folder
    }

    /// e.g. "Tally-Export-2026-06-12-1830" — sortable, filesystem-safe, unique per minute.
    private static func exportFolderName() -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd-HHmm"
        return "Tally-Export-\(fmt.string(from: Date()))"
    }

    /// Renders one table as a CSV string: a header row of column names followed by all rows,
    /// ordered by `ts` when the table has one (so the export is chronological).
    private static func csvForTable(_ table: String, _ db: GRDB.Database) throws -> String {
        let columns = try db.columns(in: table).map(\.name)
        guard !columns.isEmpty else { return "" }

        let orderBy = columns.contains("ts") ? " ORDER BY ts ASC"
            : columns.contains("day") ? " ORDER BY day ASC" : ""
        let rows = try Row.fetchAll(db, sql: "SELECT * FROM \(table)\(orderBy)")

        var lines = [columns.map(csvEscape).joined(separator: ",")]
        for row in rows {
            let cells = columns.map { col -> String in
                csvEscape(stringify(row[col]))
            }
            lines.append(cells.joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Convert a GRDB database value to a plain string. Dates are stored as text already;
    /// numbers/null come through their natural description.
    private static func stringify(_ value: DatabaseValue) -> String {
        switch value.storage {
        case .null: return ""
        case let .int64(i): return String(i)
        case let .double(d): return String(d)
        case let .string(s): return s
        case let .blob(data): return "<\(data.count) bytes>"
        }
    }

    /// Quote a field if it contains a comma, quote, or newline (RFC 4180), doubling inner quotes.
    private static func csvEscape(_ field: String) -> String {
        guard field.contains(",") || field.contains("\"") || field.contains("\n") else { return field }
        return "\"\(field.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}
