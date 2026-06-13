import Foundation

/// Parses `route -n get default` for the default route's gateway IP and interface.
/// The gateway is the "local link" ping target; the interface tells us whether traffic is
/// actually flowing over a VPN tunnel (vs. macOS's always-present utun Continuity tunnels).
enum GatewayLookup {
    /// (gateway IP, interface name) for the current default route, either may be nil.
    static func defaultRoute() -> (gateway: String?, interface: String?) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/sbin/route")
        proc.arguments = ["-n", "get", "default"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return (nil, nil) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard let out = String(data: data, encoding: .utf8) else { return (nil, nil) }
        var gateway: String?
        var iface: String?
        for line in out.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("gateway:") {
                gateway = trimmed.replacingOccurrences(of: "gateway:", with: "")
                    .trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("interface:") {
                iface = trimmed.replacingOccurrences(of: "interface:", with: "")
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        return (gateway, iface)
    }

    static func defaultGateway() -> String? {
        defaultRoute().gateway
    }
}
