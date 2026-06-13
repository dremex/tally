import SwiftUI

/// Connection quality level with an associated colour for the UI.
enum QualityLevel: String {
    case excellent = "Excellent"
    case good = "Good"
    case fair = "Fair"
    case poor = "Poor"
    case unknown = "—"

    var color: Color {
        switch self {
        case .excellent: return Theme.green
        case .good: return Theme.aqua
        case .fair: return Theme.yellow
        case .poor: return Theme.red
        case .unknown: return Theme.secondaryText
        }
    }
}

/// Pure, testable scoring: maps latency / jitter / loss to a 0–100 quality score.
/// Each component is mapped to 0–100 then blended; loss is weighted hardest because dropped
/// packets hurt real usage the most.
enum QualityScorer {
    /// Linear map of `value` in [good, bad] → [100, 0], clamped.
    private static func component(_ value: Double, good: Double, bad: Double) -> Double {
        guard bad > good else { return 100 }
        let t = (value - good) / (bad - good)
        return max(0, min(100, (1 - t) * 100))
    }

    static func score(latencyMs: Double, jitterMs: Double, lossPct: Double) -> Double {
        let latency = component(latencyMs, good: 20, bad: 200) // <20ms great, >200ms awful
        let jitter = component(jitterMs, good: 5, bad: 50) // <5ms great, >50ms awful
        let loss = component(lossPct, good: 0, bad: 10) // 0% great, ≥10% awful
        let blended = 0.45 * latency + 0.25 * jitter + 0.30 * loss
        return max(0, min(100, blended))
    }

    static func level(for score: Double) -> QualityLevel {
        switch score {
        case 85...: return .excellent
        case 65..<85: return .good
        case 40..<65: return .fair
        default: return .poor
        }
    }
}
