import Foundation

/// Display width of Unicode scalars in terminal cells, following the conventions of
/// `wcwidth` as used by xterm, tmux and most curses programs. Programs compute cursor
/// positions with these rules, so matching them keeps the screen model in sync.
enum UnicodeWidth {
    /// 0 for zero-width (combining, format) scalars, 2 for wide (East Asian Wide/Fullwidth,
    /// emoji presentation) scalars, otherwise 1.
    static func width(of scalar: Unicode.Scalar) -> Int {
        let value = scalar.value
        if value < 0x20 || (0x7F..<0xA0).contains(value) { return 0 }
        if value < 0x300 { return 1 }
        if (0x1160...0x11FF).contains(value) { return 0 }  // Hangul medial vowels and final consonants
        if value == 0x200B { return 0 }  // zero width space
        let properties = scalar.properties
        switch properties.generalCategory {
        case .nonspacingMark, .enclosingMark, .format:
            return 0
        default:
            break
        }
        if properties.isEmojiPresentation { return 2 }
        return isEastAsianWide(value) ? 2 : 1
    }

    private static let wideRanges: [ClosedRange<UInt32>] = [
        0x1100...0x115F, 0x231A...0x231B, 0x2329...0x232A, 0x23E9...0x23EC, 0x23F0...0x23F0,
        0x23F3...0x23F3, 0x25FD...0x25FE, 0x2614...0x2615, 0x2648...0x2653, 0x267F...0x267F,
        0x2693...0x2693, 0x26A1...0x26A1, 0x26AA...0x26AB, 0x26BD...0x26BE, 0x26C4...0x26C5,
        0x26CE...0x26CE, 0x26D4...0x26D4, 0x26EA...0x26EA, 0x26F2...0x26F3, 0x26F5...0x26F5,
        0x26FA...0x26FA, 0x26FD...0x26FD, 0x2705...0x2705, 0x270A...0x270B, 0x2728...0x2728,
        0x274C...0x274C, 0x274E...0x274E, 0x2753...0x2755, 0x2757...0x2757, 0x2795...0x2797,
        0x27B0...0x27B0, 0x27BF...0x27BF, 0x2B1B...0x2B1C, 0x2B50...0x2B50, 0x2B55...0x2B55,
        0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xA000...0xA4CF,
        0xA960...0xA97F, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE10...0xFE19, 0xFE30...0xFE6F,
        0xFF00...0xFF60, 0xFFE0...0xFFE6, 0x16FE0...0x16FE4, 0x17000...0x18CFF, 0x1AFF0...0x1B2FF,
        0x1F004...0x1F004, 0x1F0CF...0x1F0CF, 0x1F18E...0x1F18E, 0x1F191...0x1F19A,
        0x1F200...0x1F202, 0x1F210...0x1F23B, 0x1F240...0x1F248, 0x1F250...0x1F251,
        0x1F260...0x1F265, 0x1F300...0x1F64F, 0x1F680...0x1F6FF, 0x1F7E0...0x1F7EB,
        0x1F900...0x1F9FF, 0x1FA70...0x1FAFF, 0x20000...0x2FFFD, 0x30000...0x3FFFD,
    ]

    private static func isEastAsianWide(_ value: UInt32) -> Bool {
        var low = 0, high = wideRanges.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let range = wideRanges[mid]
            if value < range.lowerBound { high = mid - 1 } else if value > range.upperBound { low = mid + 1 } else { return true }
        }
        return false
    }
}

/// 94-character sets selectable with SCS (`ESC ( x`). Only those still used in practice.
enum CharacterSet94: Sendable, Equatable {
    case ascii
    /// DEC Special Graphics: line drawing, used by ncurses when it can't assume UTF-8.
    case decSpecialGraphics
    case unitedKingdom

    func map(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        switch self {
        case .ascii:
            return scalar
        case .unitedKingdom:
            return scalar == "#" ? "£" : scalar
        case .decSpecialGraphics:
            guard (0x5F...0x7E).contains(scalar.value) else { return scalar }
            return Self.specialGraphics[Int(scalar.value - 0x5F)]
        }
    }

    private static let specialGraphics: [Unicode.Scalar] = [
        "\u{00A0}", "◆", "▒", "␉", "␌", "␍", "␊", "°", "±", "␤", "␋", "┘", "┐", "┌", "└", "┼",
        "⎺", "⎻", "─", "⎼", "⎽", "├", "┤", "┴", "┬", "│", "≤", "≥", "π", "≠", "£", "·",
    ]
}
