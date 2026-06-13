import Foundation

/// Drives all sampling timers, updates the view model, and flushes aggregates to SQLite.
/// Runs while the app is alive (the app launches at login), giving continuous auditable history.
@MainActor
final class SamplingCoordinator {
    private let vm: NetworkViewModel
    private let db = Database.shared
    private let interfaceSampler = InterfaceSampler()
    private let nettopSampler = NettopSampler()
    private let pathMonitor = PathMonitor()

    // Latency: one probe to the public internet, one to the LAN gateway (rebuilt on path change).
    private let internetProbe = PingProbe(target: "1.1.1.1", label: "Internet")
    private var gatewayProbe: PingProbe?
    private var gatewayIP: String?

    private var liveTimer: Timer?
    private var appTimer: Timer?
    private var pruneTimer: Timer?
    private var latencyTimer: Timer?
    private var lastQualityWrite: Date?

    // Aggregation buffer: accumulate 1s readings, flush one row per `flushInterval`.
    private var aggRx: Int64 = 0
    private var aggTx: Int64 = 0
    private var aggCount: Int = 0
    private var aggStart = Date()
    private let flushInterval: TimeInterval = 10 // persist one aggregated throughput row per 10s
    private var currentInterface = "en0"

    init(viewModel: NetworkViewModel) {
        vm = viewModel
    }

    func start() {
        pathMonitor.onChange = { [weak self] type in
            Task { @MainActor in
                self?.vm.connection = type
                self?.refreshGateway()
            }
        }
        pathMonitor.start()
        refreshGateway()

        // 1s live throughput
        let live = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickLive() }
        }
        RunLoop.main.add(live, forMode: .common)
        liveTimer = live

        // ~5s per-app sampling. nettop runs off the main thread to avoid UI hitches.
        let app = Timer(timeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickApps() }
        }
        RunLoop.main.add(app, forMode: .common)
        appTimer = app

        // Hourly prune of data past retention. Database is Sendable, so call it directly.
        let database = db
        let prune = Timer(timeInterval: 3600, repeats: true) { _ in
            database.pruneOldData()
        }
        RunLoop.main.add(prune, forMode: .common)
        pruneTimer = prune
        db.pruneOldData()

        // ~2s latency probes (off-main, like nettop).
        let latency = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickLatency() }
        }
        RunLoop.main.add(latency, forMode: .common)
        latencyTimer = latency
    }

    /// Re-read the default route when the network path changes: rebuild the gateway ping probe,
    /// and decide VPN state by whether the default route runs over a tunnel interface — which is
    /// the reliable signal (macOS keeps utun0–3 up for AirDrop/Handoff/Private Relay even with no
    /// VPN, so merely "a utun exists" is a false positive).
    private func refreshGateway() {
        let route = GatewayLookup.defaultRoute()
        if route.gateway != gatewayIP {
            gatewayIP = route.gateway
            gatewayProbe = route.gateway.map { PingProbe(target: $0, label: "Gateway") }
        }
        let tunnelPrefixes = ["utun", "ipsec", "ppp", "tun", "tap"]
        let viaTunnel = route.interface.map { iface in
            tunnelPrefixes.contains { iface.hasPrefix($0) }
        } ?? false
        vm.vpnActive = viaTunnel
        vm.vpnInterfaces = viaTunnel ? [route.interface ?? ""] : []
    }

    /// Invalidate timers and stop network monitoring. Safe to call repeatedly. The coordinator
    /// currently lives for the whole app lifetime, so this exists for correctness/testability
    /// rather than because deallocation is expected.
    func stop() {
        liveTimer?.invalidate()
        liveTimer = nil
        appTimer?.invalidate()
        appTimer = nil
        pruneTimer?.invalidate()
        pruneTimer = nil
        latencyTimer?.invalidate()
        latencyTimer = nil
        pathMonitor.stop()
    }

    private func tickLive() {
        let now = Date()
        guard let sample = interfaceSampler.sample(now: now) else { return }
        vm.updateLive(sample, at: now)
        let reading = sample.total

        aggRx += reading.rxBytes
        aggTx += reading.txBytes
        aggCount += 1

        let elapsed = now.timeIntervalSince(aggStart)
        if elapsed >= flushInterval {
            let row = ThroughputSample(
                id: nil, ts: now, interface: currentInterface,
                rxBytes: aggRx, txBytes: aggTx,
                rxRate: Double(aggRx) / elapsed, txRate: Double(aggTx) / elapsed
            )
            db.insertThroughput(row)
            aggRx = 0
            aggTx = 0
            aggCount = 0
            aggStart = now
        }
    }

    private func tickApps() {
        // Run nettop off-main (it blocks ~30-80ms), then hop back to update UI + persist.
        Task.detached { [weak self] in
            guard let self else { return }
            let now = Date()
            let readings = await nettopSampler.sample(now: now)
            guard !readings.isEmpty else { return }
            let rows = readings.map {
                AppSample(
                    id: nil,
                    ts: now,
                    processName: $0.processName,
                    rxBytes: $0.rxBytes,
                    txBytes: $0.txBytes
                )
            }
            await MainActor.run {
                self.vm.updateApps(readings)
                self.db.insertAppSamples(rows)
            }
        }
    }

    private func tickLatency() {
        let internet = internetProbe
        let gateway = gatewayProbe
        Task.detached { [weak self] in
            guard let self else { return }
            // Probe in parallel; each blocks up to ~1s.
            async let net = internet.probe()
            async let gw: LatencyMetrics? = gateway?.probe()
            let netResult = await net
            let gwResult = await gw
            await MainActor.run {
                self.vm.updateLatency(gateway: gwResult, internet: netResult)
                self.maybeLogQuality(internet: netResult)
            }
        }
    }

    /// Persist a quality sample roughly every 10s (the latency tick runs every 2s). Only logs when
    /// the internet target was reachable, so unreachable blips don't pollute the score history.
    private func maybeLogQuality(internet: LatencyMetrics?) {
        guard let net = internet, net.reachable else { return }
        let now = Date()
        if let last = lastQualityWrite, now.timeIntervalSince(last) < 10 { return }
        lastQualityWrite = now
        db.insertQuality(QualitySample(
            id: nil, ts: now,
            latencyMs: net.avgMs, jitterMs: net.jitterMs, lossPct: net.lossPct,
            score: vm.qualityScore
        ))
    }
}
