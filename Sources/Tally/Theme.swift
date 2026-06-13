import SwiftUI

/// Gruvbox Material (dark, medium) palette — https://github.com/sainnhe/gruvbox-material
/// Plus semantic aliases used across the app so colours stay consistent and themeable.
enum Theme {
    // Raw palette
    static let bg0 = Color(hex: 0x282828) // base background
    static let bg1 = Color(hex: 0x32302F) // slightly raised (cards)
    static let bg2 = Color(hex: 0x3C3836)
    static let bg3 = Color(hex: 0x45403D) // borders / dividers
    static let fg = Color(hex: 0xD4BE98) // primary foreground
    static let grey = Color(hex: 0x928374) // secondary/muted

    static let red = Color(hex: 0xEA6962)
    static let orange = Color(hex: 0xE78A4E)
    static let yellow = Color(hex: 0xD8A657)
    static let green = Color(hex: 0xA9B665)
    static let aqua = Color(hex: 0x89B482)
    static let blue = Color(hex: 0x7DAEA3)
    static let purple = Color(hex: 0xD3869B)

    // Semantic aliases
    static let background = bg0
    static let card = bg1
    static let divider = bg3
    static let primaryText = fg
    static let secondaryText = grey

    static let download = blue // ↓
    static let upload = aqua // ↑ (aqua reads calmer than the olive green against the dark bg)
    static let vpn = purple
    static let alert = red

    // Brighter, more saturated variants for the macOS menu bar, where the muted in-popover
    // tones wash out against a coloured wallpaper. Used only by renderMenuBarImage().
    static let downloadBright = Color(hex: 0x4FC3E8) // vivid cyan-blue
    static let uploadBright = Color(hex: 0x9BE36A) // vivid green
}

extension Color {
    init(hex: UInt) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}
