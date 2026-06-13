import Foundation

/// Reads cumulative per-interface byte counters via getifaddrs() and diffs successive reads to
/// produce live throughput. No permissions required. This is the authoritative live-speed source.
struct InterfaceCounters {
    var rxBytes: UInt64
    var txBytes: UInt64
}

/// Result of one sampling tick: instantaneous rates plus the bytes transferred since last tick.
struct ThroughputReading {
    var rxRate: Double // bytes/sec
    var txRate: Double // bytes/sec
    var rxBytes: Int64 // bytes since previous reading
    var txBytes: Int64 // bytes since previous reading
}

/// Live rate for a single interface — for the Connection tab's per-interface breakdown.
struct InterfaceRate: Identifiable {
    var name: String // e.g. "en0"
    var rxRate: Double // bytes/sec
    var txRate: Double // bytes/sec
    var id: String {
        name
    }

    var totalRate: Double {
        rxRate + txRate
    }
}

/// A full tick: the summed throughput (for the menu bar / history) and the per-interface breakdown.
/// VPN state is derived separately from the default route (see SamplingCoordinator), not here.
struct InterfaceSample {
    var total: ThroughputReading
    var perInterface: [InterfaceRate]
}

final class InterfaceSampler {
    private var lastCounters: [String: InterfaceCounters] = [:]
    private var lastTime: Date?

    /// True for the physical/Wi-Fi interfaces whose byte counters we sum for throughput.
    private func isPhysical(_ name: String) -> Bool {
        name.hasPrefix("en") || name.hasPrefix("bridge")
    }

    /// Read cumulative byte counters for physical interfaces. Counters are kernel-cumulative
    /// since boot.
    func read() -> [String: InterfaceCounters] {
        var counters: [String: InterfaceCounters] = [:]
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else { return counters }
        defer { freeifaddrs(ifaddrPtr) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = ptr {
            defer { ptr = cur.pointee.ifa_next }
            let name = String(cString: cur.pointee.ifa_name)
            // AF_LINK entries carry the if_data byte counters.
            guard cur.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_LINK) else { continue }
            guard isPhysical(name) else { continue }
            guard let data = cur.pointee.ifa_data?.assumingMemoryBound(to: if_data.self) else { continue }
            counters[name] = InterfaceCounters(
                rxBytes: UInt64(data.pointee.ifi_ibytes),
                txBytes: UInt64(data.pointee.ifi_obytes)
            )
        }
        return counters
    }

    /// Diff against the previous read. Returns nil on the very first call (no baseline yet).
    func sample(now: Date = Date()) -> InterfaceSample? {
        let current = read()
        defer {
            lastCounters = current
            lastTime = now
        }
        guard let lastTime else { return nil }
        let dt = now.timeIntervalSince(lastTime)
        guard dt > 0 else { return nil }

        var rxDelta: Int64 = 0
        var txDelta: Int64 = 0
        var perInterface: [InterfaceRate] = []
        for (name, cur) in current {
            guard let prev = lastCounters[name] else { continue }
            // Clamp to avoid negatives from counter wrap or interface reset.
            let rx = Int64(cur.rxBytes >= prev.rxBytes ? cur.rxBytes - prev.rxBytes : 0)
            let tx = Int64(cur.txBytes >= prev.txBytes ? cur.txBytes - prev.txBytes : 0)
            rxDelta += rx
            txDelta += tx
            perInterface.append(InterfaceRate(name: name, rxRate: Double(rx) / dt, txRate: Double(tx) / dt))
        }
        perInterface.sort { $0.totalRate > $1.totalRate }
        let total = ThroughputReading(
            rxRate: Double(rxDelta) / dt,
            txRate: Double(txDelta) / dt,
            rxBytes: rxDelta,
            txBytes: txDelta
        )
        return InterfaceSample(total: total, perInterface: perInterface)
    }
}
