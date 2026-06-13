import Foundation

enum Fmt {
    /// Human-readable rate, e.g. "2.1 MB/s", "120 KB/s". Width-stable-ish (1 decimal for MB+).
    static func rate(_ bytesPerSec: Double) -> String {
        bytes(bytesPerSec) + "/s"
    }

    /// Human-readable byte count, e.g. "4.2 GB", "812 MB".
    static func bytes(_ b: Double) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = b
        var i = 0
        while value >= 1024, i < units.count - 1 {
            value /= 1024
            i += 1
        }
        if i == 0 {
            return "\(Int(value)) \(units[i])"
        } else if value >= 100 {
            return String(format: "%.0f %@", value, units[i])
        } else {
            return String(format: "%.1f %@", value, units[i])
        }
    }

    static func bytes(_ b: Int64) -> String {
        bytes(Double(b))
    }

    /// Compact rate for the menu bar — shorter, e.g. "2.1M", "120K", "0".
    static func compactRate(_ bytesPerSec: Double) -> String {
        let b = bytesPerSec
        if b < 1024 { return "\(Int(b))" }
        if b < 1024 * 1024 { return String(format: "%.0fK", b / 1024) }
        return String(format: "%.1fM", b / (1024 * 1024))
    }
}
