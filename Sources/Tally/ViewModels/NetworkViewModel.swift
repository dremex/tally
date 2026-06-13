import AppKit
import Foundation
import SwiftUI

/// Point for the live sparkline / history-ish recent chart.
struct RatePoint: Identifiable {
    let id = UUID()
    var time: Date
    var rxRate: Double
    var txRate: Double
}

/// Central observable state for all views. Updated on the main thread by SamplingCoordinator.
@MainActor
final class NetworkViewModel: ObservableObject {
    // Live
    @Published var rxRate: Double = 0
    @Published var txRate: Double = 0
    @Published var connection: PathMonitor.ConnectionType = .other
    @Published var recent: [RatePoint] = [] // rolling last ~5 min for the live sparkline

    /// Per-app (live)
    @Published var appReadings: [AppReading] = []
    /// When the live app list last refreshed (nettop sample). Drives the refresh-countdown bar.
    @Published var lastAppRefresh: Date?
    /// Nominal interval between nettop samples — keep in sync with SamplingCoordinator's appTimer.
    let appRefreshInterval: TimeInterval = 5

    // Connection / quality
    @Published var perInterface: [InterfaceRate] = []
    @Published var vpnActive = false
    @Published var vpnInterfaces: [String] = []
    @Published var gatewayLatency: LatencyMetrics?
    @Published var internetLatency: LatencyMetrics?
    @Published var qualityScore: Double = 0
    @Published var qualityLevel: QualityLevel = .unknown

    /// Keep ~5 minutes of 1s points for the live sparkline.
    private let recentCapacity = 300

    func updateLive(_ sample: InterfaceSample, at time: Date) {
        let reading = sample.total
        // Only publish when a value actually changes: every assignment to an @Published fires
        // objectWillChange and forces dependent views (incl. the always-present menu-bar label)
        // to redraw. When the network is idle these are 0→0 writes, so guarding them eliminates
        // a per-second redraw that otherwise runs forever whether or not the popover is open.
        if reading.rxRate != rxRate { rxRate = reading.rxRate }
        if reading.txRate != txRate { txRate = reading.txRate }
        if sample.perInterface != perInterface { perInterface = sample.perInterface }
        // vpnActive/vpnInterfaces are set by the coordinator from the default-route interface,
        // not from "any utun exists" — see SamplingCoordinator.refreshGateway().
        recent.append(RatePoint(time: time, rxRate: reading.rxRate, txRate: reading.txRate))
        if recent.count > recentCapacity {
            recent.removeFirst(recent.count - recentCapacity)
        }
    }

    func updateApps(_ readings: [AppReading]) {
        appReadings = readings
        lastAppRefresh = Date()
    }

    /// Update latency metrics and recompute the quality score (driven by the internet target).
    func updateLatency(gateway: LatencyMetrics?, internet: LatencyMetrics?) {
        gatewayLatency = gateway
        internetLatency = internet
        if let net = internet, net.reachable {
            qualityScore = QualityScorer.score(
                latencyMs: net.avgMs,
                jitterMs: net.jitterMs,
                lossPct: net.lossPct
            )
            qualityLevel = QualityScorer.level(for: qualityScore)
        } else if internet != nil {
            // Probed but unreachable → poor/zero.
            qualityScore = 0
            qualityLevel = .poor
        } else {
            qualityLevel = .unknown
        }
    }

    /// Compact menu-bar label: "↓ 2.1M ↑ 120K".
    var menuBarText: String {
        "↓ \(Fmt.compactRate(rxRate)) ↑ \(Fmt.compactRate(txRate))"
    }

    /// The menu bar renders labels as monochrome template images, so a coloured SwiftUI `Text`
    /// gets flattened. To actually colour the down/up parts we draw an NSImage ourselves (marked
    /// non-template so the colours survive) and use it as the MenuBarExtra label.
    private var cachedMenuBarText: String?
    private var cachedMenuBarImage: NSImage?

    func renderMenuBarImage() -> NSImage {
        // The visible label is the *formatted* string ("↓ 2.1M ↑ 120K"), which is far coarser than
        // the raw rates — small per-second fluctuations don't change it. Redrawing the NSImage is
        // real CoreGraphics work (lockFocus/draw/unlockFocus); cache on the rendered text so we only
        // rebuild when the label actually changes, not on every tick.
        let text = menuBarText
        if text == cachedMenuBarText, let cached = cachedMenuBarImage {
            return cached
        }

        // Heavier + brighter than the in-popover palette: the menu bar sits on a coloured
        // wallpaper, where the muted Gruvbox tones wash out. Use the brighter accent variants.
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
        let down = NSColor(Theme.downloadBright)
        let up = NSColor(Theme.uploadBright)

        let s = NSMutableAttributedString()
        s.append(NSAttributedString(
            string: "↓ \(Fmt.compactRate(rxRate))",
            attributes: [.font: font, .foregroundColor: down]
        ))
        s.append(NSAttributedString(
            string: "  ↑ \(Fmt.compactRate(txRate))",
            attributes: [.font: font, .foregroundColor: up]
        ))

        let size = s.size()
        let pad: CGFloat = 2
        let image = NSImage(size: NSSize(width: ceil(size.width) + pad * 2, height: 18))
        image.lockFocus()
        s.draw(at: NSPoint(x: pad, y: (18 - size.height) / 2))
        image.unlockFocus()
        image.isTemplate = false // keep our colours; don't let the menu bar monochrome it
        cachedMenuBarText = text
        cachedMenuBarImage = image
        return image
    }
}
