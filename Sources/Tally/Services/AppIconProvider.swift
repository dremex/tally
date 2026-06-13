import AppKit

/// Resolves a process name (as reported by nettop, e.g. "Spotify Helper", "Google Chrome H")
/// to an app icon. nettop names are messy: helper/renderer processes ("Slack Helper"), truncated
/// names ("Google Chrome H"), and "(Plugin)" suffixes all need to map to the *parent* GUI app,
/// whose bundle carries the real icon (helper bundles usually don't). CLI processes like the
/// Claude Code "claude" binary have no GUI app and fall back to a generic icon.
@MainActor
final class AppIconProvider {
    static let shared = AppIconProvider()

    /// NSCache auto-evicts under memory pressure, so the resolved-icon cache stays bounded
    /// even as new process names accrue over a long-running session.
    private let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 256
        return c
    }()

    private let genericIcon = NSWorkspace.shared.icon(for: .applicationBundle)

    /// Fallback for CLI / daemon processes with no GUI app (e.g. the Claude Code "claude" binary,
    /// node, mDNSResponder): a terminal glyph, which reads better than the blank app placeholder.
    private let cliIcon: NSImage = {
        let cfg = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        guard let img = NSImage(
            systemSymbolName: "terminal",
            accessibilityDescription: "Command-line process"
        )?
            .withSymbolConfiguration(cfg) else {
            return NSWorkspace.shared.icon(for: .applicationBundle)
        }
        img.isTemplate = true // adopt the row's foreground color so it's visible in dark mode
        return img
    }()

    func icon(for processName: String) -> NSImage {
        let key = processName as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let resolved = resolve(processName) ?? cliIcon
        cache.setObject(resolved, forKey: key)
        return resolved
    }

    /// Strip the noise nettop appends so "Slack Helper", "Google Chrome H",
    /// "Helium Helper (Plugin)" all reduce toward their parent app name.
    private func baseName(_ raw: String) -> String {
        var s = raw
        if let paren = s.range(of: " (") { s = String(s[..<paren.lowerBound]) }
        // Drop a trailing "Helper" / "Renderer" / "GPU" word (and the truncated "H" nettop emits).
        for suffix in [" Helper", " Renderer", " GPU", " Web Content", " Networking", " H"]
            where s.hasSuffix(suffix) {
            s = String(s.dropLast(suffix.count))
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    private func resolve(_ processName: String) -> NSImage? {
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy != .prohibited && $0.localizedName != nil }

        let candidates = [processName.lowercased(), baseName(processName).lowercased()]

        for needle in candidates where !needle.isEmpty {
            // Among all apps whose name is a prefix of the needle (or vice-versa), prefer the one
            // with the SHORTEST name — that's the parent app ("Steam") over a helper ("Steam Helper"),
            // whose bundle actually carries a real icon.
            let match = running
                .compactMap { app -> (NSRunningApplication, String)? in
                    guard let name = app.localizedName?.lowercased() else { return nil }
                    if needle == name || needle.hasPrefix(name) || name.hasPrefix(needle) {
                        return (app, name)
                    }
                    return nil
                }
                .min { $0.1.count < $1.1.count }?
                .0
            if let icon = match?.icon, !isGeneric(icon) {
                return icon
            }
        }
        return nil
    }

    /// The shared generic app icon compares equal by name; use that to reject placeholder icons
    /// so we can fall through to a better candidate.
    private func isGeneric(_ icon: NSImage) -> Bool {
        icon.name() == genericIcon.name() && icon.name() != nil
    }
}
