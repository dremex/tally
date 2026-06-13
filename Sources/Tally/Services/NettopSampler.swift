import Foundation

/// Per-process network usage for one sampling window.
struct AppReading: Identifiable {
    var processName: String
    var rxBytes: Int64 // bytes since previous reading
    var txBytes: Int64
    var rxRate: Double // bytes/sec
    var txRate: Double
    var id: String {
        processName
    }

    var totalRate: Double {
        rxRate + txRate
    }
}

/// Runs `nettop` one-shot and parses per-process cumulative byte counters, diffing against the
/// previous run to produce per-window deltas + rates.
///
/// nettop output with `-J bytes_in,bytes_out` is CSV: a header line, then rows like
///   `Safari.4823,10485760,2097152,`
/// The first column is `name.pid`; some rows are routes/aggregates rather than processes — we
/// group everything by the leading process name, which is best-effort but matches Activity Monitor.
actor NettopSampler {
    private var lastCumulative: [String: (rx: Int64, tx: Int64)] = [:]
    private var lastTime: Date?

    func sample(now: Date = Date()) -> [AppReading] {
        guard let raw = runNettop() else { return [] }
        let cumulative = parse(raw)
        defer {
            lastCumulative = cumulative
            lastTime = now
        }
        guard let lastTime else { return [] }
        let dt = now.timeIntervalSince(lastTime)
        guard dt > 0 else { return [] }

        var readings: [AppReading] = []
        for (name, cur) in cumulative {
            let prev = lastCumulative[name] ?? (rx: cur.rx, tx: cur.tx)
            // Clamp negatives: a process that exited and a new one reused isn't tracked across runs.
            let rxDelta = max(0, cur.rx - prev.rx)
            let txDelta = max(0, cur.tx - prev.tx)
            guard rxDelta > 0 || txDelta > 0 else { continue }
            readings.append(AppReading(
                processName: name,
                rxBytes: rxDelta,
                txBytes: txDelta,
                rxRate: Double(rxDelta) / dt,
                txRate: Double(txDelta) / dt
            ))
        }
        return readings.sorted { $0.totalRate > $1.totalRate }
    }

    private func runNettop() -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        proc.arguments = ["-P", "-L", "1", "-x", "-J", "bytes_in,bytes_out"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
        } catch {
            NSLog("nettop launch failed: \(error)")
            return nil
        }
        // Read fully BEFORE waiting: draining the pipe lets nettop finish writing and exit.
        // Output is ~1KB (well under the 64KB pipe buffer), so a single blocking read is safe.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    /// Parse CSV into cumulative bytes per process name (summing all PIDs of the same name).
    private func parse(_ raw: String) -> [String: (rx: Int64, tx: Int64)] {
        NettopParser.parse(raw).mapValues { (rx: $0.rx, tx: $0.tx) }
    }
}

/// Pure, testable parser for `nettop -J bytes_in,bytes_out` CSV output. Extracted from the actor
/// so it can be unit-tested directly without launching a process.
enum NettopParser {
    struct Bytes: Equatable { var rx: Int64
        var tx: Int64
    }

    static func parse(_ raw: String) -> [String: Bytes] {
        var result: [String: Bytes] = [:]
        for line in raw.split(separator: "\n") {
            let cols = line.split(separator: ",", omittingEmptySubsequences: false)
            guard cols.count >= 3 else { continue }
            let firstCol = cols[0].trimmingCharacters(in: .whitespaces)
            // Skip the header row ("" then "bytes_in"...) and empty leading cells.
            guard !firstCol.isEmpty, firstCol != "bytes_in" else { continue }
            guard let rx = Int64(cols[1].trimmingCharacters(in: .whitespaces)),
                  let tx = Int64(cols[2].trimmingCharacters(in: .whitespaces)) else { continue }
            // Strip the trailing ".pid" to group by process name.
            let name: String = if let dot = firstCol.lastIndex(of: "."),
                                  Int(firstCol[firstCol.index(after: dot)...]) != nil {
                String(firstCol[..<dot])
            } else {
                firstCol
            }
            let existing = result[name] ?? Bytes(rx: 0, tx: 0)
            result[name] = Bytes(rx: existing.rx + rx, tx: existing.tx + tx)
        }
        return result
    }
}
