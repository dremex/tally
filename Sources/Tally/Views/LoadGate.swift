import SwiftUI

/// Guards against stale async-read results clobbering newer ones. Each `reload()` calls `begin()` to
/// claim a fresh token; when its read returns, `isCurrent(token)` is true only if no later reload has
/// since claimed one. Replaces the hand-rolled `loadGen += 1 / let gen = loadGen / guard gen == loadGen`
/// pattern that was copy-pasted (and had drifted) across the Network and Stats tabs.
struct LoadGate {
    private var generation = 0

    /// Claim the latest token. Call once per reload, before firing the async read.
    mutating func begin() -> Int {
        generation += 1
        return generation
    }

    /// True only if `token` is still the most recently claimed one.
    func isCurrent(_ token: Int) -> Bool {
        token == generation
    }
}
