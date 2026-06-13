import Foundation

/// Rolling latency/jitter/loss metrics for one ping target.
struct LatencyMetrics {
    var target: String // host pinged
    var label: String // "Gateway" / "Internet"
    var avgMs: Double // average of successful probes in the window
    var minMs: Double
    var maxMs: Double
    var jitterMs: Double // stddev of consecutive deltas (RFC-ish jitter)
    var lossPct: Double // % of probes in the window with no reply
    var lastMs: Double? // most recent successful probe (nil if it was lost)
    var reachable: Bool // any successful probe in the window
}

/// Pings a host with one-shot `/sbin/ping` probes and keeps a rolling window of results.
/// An `actor` because it's driven from a detached task off the main thread (like NettopSampler).
actor PingProbe {
    let target: String
    let label: String
    private let windowSize: Int
    private var samples: [Double?] = [] // ms, or nil for a lost probe

    init(target: String, label: String, windowSize: Int = 60) {
        self.target = target
        self.label = label
        self.windowSize = windowSize
    }

    /// Run one ping (1 packet, 1s timeout) and record the result. Returns the latest metrics.
    func probe() -> LatencyMetrics {
        let ms = runPing()
        samples.append(ms)
        if samples.count > windowSize { samples.removeFirst(samples.count - windowSize) }
        return metrics()
    }

    private func runPing() -> Double? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/sbin/ping")
        // -c 1 one packet; -t 1 TTL-ish/timeout guard; -W 1000 wait up to 1000ms for reply.
        proc.arguments = ["-c", "1", "-W", "1000", target]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0,
              let out = String(data: data, encoding: .utf8) else { return nil }
        // Parse "time=12.345 ms"
        guard let range = out.range(of: "time=") else { return nil }
        let tail = out[range.upperBound...]
        let numStr = tail.prefix { $0.isNumber || $0 == "." }
        return Double(numStr)
    }

    private func metrics() -> LatencyMetrics {
        let oks = samples.compactMap(\.self)
        let lost = samples.count - oks.count
        let loss = samples.isEmpty ? 0 : Double(lost) / Double(samples.count) * 100
        let avg = oks.isEmpty ? 0 : oks.reduce(0, +) / Double(oks.count)
        // Jitter: mean absolute difference between consecutive successful probes.
        var jitter = 0.0
        if oks.count > 1 {
            var deltas = 0.0
            for i in 1..<oks.count {
                deltas += abs(oks[i] - oks[i - 1])
            }
            jitter = deltas / Double(oks.count - 1)
        }
        return LatencyMetrics(
            target: target, label: label,
            avgMs: avg, minMs: oks.min() ?? 0, maxMs: oks.max() ?? 0,
            jitterMs: jitter, lossPct: loss,
            lastMs: samples.last.flatMap(\.self), reachable: !oks.isEmpty
        )
    }
}
