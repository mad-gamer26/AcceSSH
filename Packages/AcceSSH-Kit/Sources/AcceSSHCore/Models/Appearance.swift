import Foundation

/// An sRGB color with 8-bit components.
public struct RGBColor: Codable, Hashable, Sendable {
    public var red: UInt8
    public var green: UInt8
    public var blue: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// Creates a color from `0xRRGGBB`.
    public init(hex: UInt32) {
        self.init(red: UInt8((hex >> 16) & 0xFF), green: UInt8((hex >> 8) & 0xFF), blue: UInt8(hex & 0xFF))
    }

    /// Parses `#RRGGBB` or `RRGGBB`.
    public init?(hexString: String) {
        var text = hexString.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(hex: value)
    }

    public var hexString: String { String(format: "#%02X%02X%02X", red, green, blue) }

    /// WCAG relative luminance.
    public var relativeLuminance: Double {
        func channel(_ value: UInt8) -> Double {
            let c = Double(value) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
    }

    /// WCAG contrast ratio between two colors (1...21).
    public func contrastRatio(with other: RGBColor) -> Double {
        let a = relativeLuminance, b = other.relativeLuminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}

/// A terminal color theme. The 256-color palette is derived: entries 0–15 come from
/// ``ansi``, 16–231 are the xterm 6×6×6 cube and 232–255 the grayscale ramp.
public struct TerminalTheme: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var foreground: RGBColor
    public var background: RGBColor
    public var cursor: RGBColor
    public var cursorText: RGBColor
    public var selectionBackground: RGBColor
    public var selectionForeground: RGBColor?
    public var hyperlink: RGBColor
    /// The 16 ANSI colors: black, red, green, yellow, blue, magenta, cyan, white, then bright variants.
    public var ansi: [RGBColor]
    public var isDark: Bool

    public init(
        id: UUID = UUID(), name: String, foreground: RGBColor, background: RGBColor, cursor: RGBColor,
        cursorText: RGBColor, selectionBackground: RGBColor, selectionForeground: RGBColor? = nil,
        hyperlink: RGBColor, ansi: [RGBColor], isDark: Bool
    ) {
        precondition(ansi.count == 16, "A theme needs exactly 16 ANSI colors")
        self.id = id
        self.name = name
        self.foreground = foreground
        self.background = background
        self.cursor = cursor
        self.cursorText = cursorText
        self.selectionBackground = selectionBackground
        self.selectionForeground = selectionForeground
        self.hyperlink = hyperlink
        self.ansi = ansi
        self.isDark = isDark
    }

    /// Resolves an xterm 256-color index.
    public func color(forIndex index: UInt8) -> RGBColor {
        let i = Int(index)
        if i < 16 { return ansi[i] }
        if i < 232 {
            let levels: [UInt8] = [0, 95, 135, 175, 215, 255]
            let n = i - 16
            return RGBColor(red: levels[n / 36], green: levels[(n / 6) % 6], blue: levels[n % 6])
        }
        let gray = UInt8(8 + (i - 232) * 10)
        return RGBColor(red: gray, green: gray, blue: gray)
    }
}

extension TerminalTheme {
    // Fixed identifiers so hosts can reference built-in themes across launches.
    public static let highContrastDarkID = UUID(uuidString: "6A1F0C1E-3E39-4F67-9C50-7B9A9F1D0001")!
    public static let highContrastLightID = UUID(uuidString: "6A1F0C1E-3E39-4F67-9C50-7B9A9F1D0002")!
    public static let classicDarkID = UUID(uuidString: "6A1F0C1E-3E39-4F67-9C50-7B9A9F1D0003")!
    public static let classicLightID = UUID(uuidString: "6A1F0C1E-3E39-4F67-9C50-7B9A9F1D0004")!

    /// White on black with every ANSI color meeting at least 4.5:1 contrast against the background.
    public static let highContrastDark = TerminalTheme(
        id: highContrastDarkID, name: "High Contrast Dark",
        foreground: RGBColor(hex: 0xFFFFFF), background: RGBColor(hex: 0x000000),
        cursor: RGBColor(hex: 0xFFD700), cursorText: RGBColor(hex: 0x000000),
        selectionBackground: RGBColor(hex: 0x0050C8), selectionForeground: RGBColor(hex: 0xFFFFFF),
        hyperlink: RGBColor(hex: 0x6CB6FF),
        ansi: [
            0x767676, 0xFF6B6B, 0x5FD75F, 0xFFD75F, 0x6CB6FF, 0xF08CFF, 0x5FD7D7, 0xE0E0E0,
            0x9E9E9E, 0xFF9494, 0x87FF87, 0xFFFF87, 0x9CCBFF, 0xF8B4FF, 0x87FFFF, 0xFFFFFF,
        ].map(RGBColor.init(hex:)),
        isDark: true
    )

    /// Black on white with every ANSI color meeting at least 4.5:1 contrast against the background.
    public static let highContrastLight = TerminalTheme(
        id: highContrastLightID, name: "High Contrast Light",
        foreground: RGBColor(hex: 0x000000), background: RGBColor(hex: 0xFFFFFF),
        cursor: RGBColor(hex: 0x0040C0), cursorText: RGBColor(hex: 0xFFFFFF),
        selectionBackground: RGBColor(hex: 0xB4D2FF), selectionForeground: RGBColor(hex: 0x000000),
        hyperlink: RGBColor(hex: 0x0040C0),
        ansi: [
            0x000000, 0xB00000, 0x006B00, 0x6B5000, 0x0030B0, 0x8B008B, 0x006B6B, 0x595959,
            0x404040, 0xC00000, 0x007A00, 0x7A5C00, 0x0040C0, 0x9E009E, 0x007A7A, 0x000000,
        ].map(RGBColor.init(hex:)),
        isDark: false
    )

    /// The traditional xterm palette.
    public static let classicDark = TerminalTheme(
        id: classicDarkID, name: "Classic Dark",
        foreground: RGBColor(hex: 0xE5E5E5), background: RGBColor(hex: 0x1E1E1E),
        cursor: RGBColor(hex: 0xE5E5E5), cursorText: RGBColor(hex: 0x1E1E1E),
        selectionBackground: RGBColor(hex: 0x3A5A8C), hyperlink: RGBColor(hex: 0x5C9CFF),
        ansi: [
            0x000000, 0xCD0000, 0x00CD00, 0xCDCD00, 0x0000EE, 0xCD00CD, 0x00CDCD, 0xE5E5E5,
            0x7F7F7F, 0xFF0000, 0x00FF00, 0xFFFF00, 0x5C5CFF, 0xFF00FF, 0x00FFFF, 0xFFFFFF,
        ].map(RGBColor.init(hex:)),
        isDark: true
    )

    /// Light palette darkened so every color (1–6, 9–14) keeps 4.5:1 contrast on the background.
    public static let classicLight = TerminalTheme(
        id: classicLightID, name: "Classic Light",
        foreground: RGBColor(hex: 0x1E1E1E), background: RGBColor(hex: 0xFAFAFA),
        cursor: RGBColor(hex: 0x1E1E1E), cursorText: RGBColor(hex: 0xFAFAFA),
        selectionBackground: RGBColor(hex: 0xC6DBF7), hyperlink: RGBColor(hex: 0x0645AD),
        ansi: [
            0x000000, 0xC91B00, 0x007A00, 0x7A6500, 0x0225C7, 0xB928C0, 0x007C86, 0x8C8C8C,
            0x686868, 0xC4302B, 0x1E7F1E, 0x7A6A00, 0x3D47E0, 0xA020A0, 0x00737C, 0x1E1E1E,
        ].map(RGBColor.init(hex:)),
        isDark: false
    )

    public static let builtIn: [TerminalTheme] = [highContrastDark, highContrastLight, classicDark, classicLight]
}

public enum CursorShape: String, Codable, CaseIterable, Sendable {
    case block, underline, bar
}

public enum TerminalFontWeight: String, Codable, CaseIterable, Sendable {
    case light, regular, medium, semibold, bold
}

public enum BoldTextRendering: String, Codable, CaseIterable, Sendable {
    /// Use a bold font face.
    case boldFont
    /// Use the bright variant of ANSI colors 0–7, as classic terminals did.
    case brightColors
    case boldFontAndBrightColors
}

/// Visual appearance (an "appearance profile").
public struct AppearanceSettings: Codable, Hashable, Sendable {
    public var fontName: String
    public var fontSize: Double
    public var fontWeight: TerminalFontWeight
    /// Scale fontSize with Dynamic Type / the system text size.
    public var followsSystemTextSize: Bool
    /// Extra space between rows as a multiple of the font's line height (1.0 = none).
    public var lineSpacing: Double
    /// Extra points between character cells.
    public var characterSpacing: Double
    /// Theme used when the system appearance is dark, or always when not following the system.
    public var darkThemeID: UUID
    public var lightThemeID: UUID
    public var followsSystemAppearance: Bool
    public var cursorShape: CursorShape
    public var cursorBlinks: Bool
    /// Overrides the theme cursor color when set.
    public var cursorColor: RGBColor?
    public var boldRendering: BoldTextRendering
    /// Opacity multiplier for SGR 2 (dim) text, clamped so dim text keeps 3:1 contrast.
    public var dimOpacity: Double
    public var underlineHyperlinks: Bool
    public var padding: Double
    /// Background opacity (1 = opaque). Forced to 1 when Reduce Transparency is on.
    public var backgroundOpacity: Double

    public init(
        fontName: String = "SF Mono",
        fontSize: Double = 14,
        fontWeight: TerminalFontWeight = .regular,
        followsSystemTextSize: Bool = true,
        lineSpacing: Double = 1.0,
        characterSpacing: Double = 0,
        darkThemeID: UUID = TerminalTheme.classicDarkID,
        lightThemeID: UUID = TerminalTheme.classicLightID,
        followsSystemAppearance: Bool = true,
        cursorShape: CursorShape = .block,
        cursorBlinks: Bool = false,
        cursorColor: RGBColor? = nil,
        boldRendering: BoldTextRendering = .boldFont,
        dimOpacity: Double = 0.7,
        underlineHyperlinks: Bool = true,
        padding: Double = 6,
        backgroundOpacity: Double = 1
    ) {
        self.fontName = fontName
        self.fontSize = fontSize
        self.fontWeight = fontWeight
        self.followsSystemTextSize = followsSystemTextSize
        self.lineSpacing = lineSpacing
        self.characterSpacing = characterSpacing
        self.darkThemeID = darkThemeID
        self.lightThemeID = lightThemeID
        self.followsSystemAppearance = followsSystemAppearance
        self.cursorShape = cursorShape
        self.cursorBlinks = cursorBlinks
        self.cursorColor = cursorColor
        self.boldRendering = boldRendering
        self.dimOpacity = dimOpacity
        self.underlineHyperlinks = underlineHyperlinks
        self.padding = padding
        self.backgroundOpacity = backgroundOpacity
    }
}
