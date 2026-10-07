import Foundation

/// A color reference as stored in the terminal model. Concrete RGB is resolved by the
/// renderer from the active theme, so a theme change recolors existing output too.
public enum TerminalColor: Hashable, Sendable {
    case `default`
    case indexed(UInt8)
    case rgb(red: UInt8, green: UInt8, blue: UInt8)
}

public struct TextAttributeFlags: OptionSet, Hashable, Sendable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let bold = TextAttributeFlags(rawValue: 1 << 0)
    public static let dim = TextAttributeFlags(rawValue: 1 << 1)
    public static let italic = TextAttributeFlags(rawValue: 1 << 2)
    public static let underline = TextAttributeFlags(rawValue: 1 << 3)
    public static let doubleUnderline = TextAttributeFlags(rawValue: 1 << 4)
    public static let curlyUnderline = TextAttributeFlags(rawValue: 1 << 5)
    public static let blink = TextAttributeFlags(rawValue: 1 << 6)
    public static let inverse = TextAttributeFlags(rawValue: 1 << 7)
    public static let hidden = TextAttributeFlags(rawValue: 1 << 8)
    public static let strikethrough = TextAttributeFlags(rawValue: 1 << 9)
    public static let overline = TextAttributeFlags(rawValue: 1 << 10)

    static let anyUnderline: TextAttributeFlags = [.underline, .doubleUnderline, .curlyUnderline]
}

public struct CellAttributes: Hashable, Sendable {
    public var foreground: TerminalColor
    public var background: TerminalColor
    public var flags: TextAttributeFlags

    public init(foreground: TerminalColor = .default, background: TerminalColor = .default, flags: TextAttributeFlags = []) {
        self.foreground = foreground
        self.background = background
        self.flags = flags
    }

    public static let `default` = CellAttributes()

    /// Attributes for cells cleared by erase operations: only the background survives
    /// ("background color erase", as xterm does).
    var erased: CellAttributes { CellAttributes(background: background) }

    /// Whether the cell is visually emphasized in a way menus use to mark a selection.
    public var isHighlighted: Bool { flags.contains(.inverse) || background != .default }
}

/// One character cell.
public struct TerminalCell: Hashable, Sendable {
    /// The grapheme cluster displayed in this cell (combining marks are part of it).
    public var character: Character
    /// 1 for normal cells, 2 for the leading half of a wide character, 0 for the trailing half.
    public var width: UInt8
    public var attributes: CellAttributes
    /// Hyperlink identifier (see ``TerminalEmulator/hyperlink(id:)``); 0 when none.
    public var hyperlinkID: UInt32

    public init(character: Character = " ", width: UInt8 = 1, attributes: CellAttributes = .default, hyperlinkID: UInt32 = 0) {
        self.character = character
        self.width = width
        self.attributes = attributes
        self.hyperlinkID = hyperlinkID
    }

    public static let blank = TerminalCell()

    static func blank(_ attributes: CellAttributes) -> TerminalCell {
        TerminalCell(character: " ", width: 1, attributes: attributes, hyperlinkID: 0)
    }

    public var isWideContinuation: Bool { width == 0 }
}

/// One row of cells.
public struct TerminalLine: Hashable, Sendable {
    public var cells: [TerminalCell]
    /// The row was soft-wrapped: its text continues on the next row without a line break.
    public var isWrapped: Bool

    public init(columns: Int, attributes: CellAttributes = .default) {
        cells = Array(repeating: TerminalCell.blank(attributes), count: max(columns, 0))
        isWrapped = false
    }

    public init(cells: [TerminalCell], isWrapped: Bool = false) {
        self.cells = cells
        self.isWrapped = isWrapped
    }

    /// The row's text. Trailing spaces are trimmed unless the row wraps onto the next one.
    public var text: String { text(trimmingTrailingSpaces: !isWrapped) }

    public func text(trimmingTrailingSpaces: Bool) -> String {
        text(columns: 0..<cells.count, trimmingTrailingSpaces: trimmingTrailingSpaces)
    }

    /// Text of a column range (clamped). Trailing halves of wide characters are skipped.
    public func text(columns: Range<Int>, trimmingTrailingSpaces: Bool) -> String {
        let lower = min(max(columns.lowerBound, 0), cells.count)
        let upper = min(max(columns.upperBound, lower), cells.count)
        var result = ""
        result.reserveCapacity(upper - lower)
        for index in lower..<upper where cells[index].width != 0 {
            result.append(cells[index].attributes.flags.contains(.hidden) ? " " : cells[index].character)
        }
        if trimmingTrailingSpaces {
            while result.last == " " { result.removeLast() }
        }
        return result
    }

    public var isBlank: Bool { cells.allSatisfy { $0.character == " " } }

    /// Column of the first cell whose text offset (in Characters) reaches `offset`.
    public func column(forCharacterOffset offset: Int) -> Int {
        var count = 0
        for (index, cell) in cells.enumerated() where cell.width != 0 {
            if count == offset { return index }
            count += 1
        }
        return cells.count
    }

    /// Character offset of a column within ``text``.
    public func characterOffset(forColumn column: Int) -> Int {
        var count = 0
        for index in 0..<min(column, cells.count) where cells[index].width != 0 {
            count += 1
        }
        return count
    }
}

/// An absolute position in the terminal history: `row` counts every line ever written to
/// the primary screen (it never changes as content scrolls), `column` is the cell column.
public struct TerminalPosition: Hashable, Comparable, Codable, Sendable {
    public var row: Int
    public var column: Int

    public init(row: Int, column: Int) {
        self.row = row
        self.column = column
    }

    public static func < (lhs: TerminalPosition, rhs: TerminalPosition) -> Bool {
        lhs.row != rhs.row ? lhs.row < rhs.row : lhs.column < rhs.column
    }
}

/// A hyperlink created with OSC 8.
public struct TerminalHyperlink: Hashable, Sendable {
    public var uri: String
    /// The application-supplied `id=` parameter, if any.
    public var identifier: String?

    /// Scheme plus host (or the whole URI when it has no host), so VoiceOver can say where
    /// a link really goes even when the visible text says something else.
    public var spokenDestination: String {
        guard let url = URL(string: uri) else { return uri }
        if let host = url.host(percentEncoded: false) { return "\(url.scheme ?? "link") link to \(host)" }
        return uri
    }
}
