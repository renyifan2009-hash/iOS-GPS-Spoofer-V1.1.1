import Foundation

/// A colour as red, green and blue from 0 to 1 (sRGB).
struct RGB: Equatable {
    let r: Double
    let g: Double
    let b: Double

    init(r: Double, g: Double, b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }

    init(hex: UInt32) {
        self.init(r: Double((hex >> 16) & 0xFF) / 255, g: Double((hex >> 8) & 0xFF) / 255, b: Double(hex & 0xFF) / 255)
    }

    /// WCAG relative luminance.
    var luminance: Double {
        func linear(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }

    /// WCAG contrast ratio, 1 to 21. Small text needs 4.5.
    func contrast(with other: RGB) -> Double {
        let a = luminance, b = other.luminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}

/// Colours for small text. The brand's bright amber, green and red are fine for icons and glows,
/// and on dark backgrounds, but on a light window amber is about 2:1 and green 2.3:1. In light
/// mode small text uses these darker tones of the same hue. In dark mode, brighter ones.
enum TextTones {
    struct Tone {
        let light: RGB
        let dark: RGB
    }

    static let warning = Tone(light: RGB(hex: 0xA14A07), dark: RGB(hex: 0xF59E0B))
    static let live = Tone(light: RGB(hex: 0x126E33), dark: RGB(hex: 0x22C55E))
    static let danger = Tone(light: RGB(hex: 0xB91C1C), dark: RGB(hex: 0xF87171))

    /// The window background in light mode (white for cards, a light grey for the window itself)
    /// and in dark mode.
    static let lightBackgrounds = [RGB(hex: 0xFFFFFF), RGB(hex: 0xECECEC)]
    static let darkBackgrounds = [RGB(hex: 0x1E1E1E), RGB(hex: 0x2A2A2A)]
}
