import Foundation
import AcceSSHShellIntegration

/// A VT220/xterm-compatible terminal emulator with a semantic model.
///
/// This class is the single source of truth for terminal state. The visual renderer and
/// the VoiceOver layer both read from it (directly or through snapshots); neither derives
/// information from the other. It performs no I/O: bytes go in through ``feed(_:)`` and a
/// ``TerminalUpdate`` comes out describing changes, events and bytes to send back.
///
/// Thread safety: not thread-safe. Each session confines its emulator to one isolation
/// domain (the session actor) and hands Sendable snapshots and updates to the UI.
public final class TerminalEmulator {
    struct CursorState {
        var row = 0
        var column = 0
        var attributes = CellAttributes.default
        var hyperlinkID: UInt32 = 0
        var pendingWrap = false
        var g0 = CharacterSet94.ascii
        var g1 = CharacterSet94.ascii
        var shiftOut = false
    }

    struct SavedCursor {
        var cursor: CursorState
        var originMode: Bool
        var autoWrap: Bool
    }

    struct ScreenBuffer {
        var lines: [TerminalLine]
        var savedCursor: SavedCursor?
    }

    static let primaryIndex = 0
    static let alternateIndex = 1
    static let maximumColumns = 1_000
    static let maximumRows = 500

    public private(set) var columns: Int
    public private(set) var rows: Int
    public internal(set) var modes = TerminalModes()
    public internal(set) var title = ""
    public internal(set) var iconTitle = ""
    public internal(set) var workingDirectory: String?

    /// Maximum lines kept in scrollback. Lowering it trims immediately.
    public var scrollbackLimit: Int {
        didSet { scrollbackLimit = max(0, scrollbackLimit); trimScrollback(force: true) }
    }

    /// Colors reported to applications that query them (OSC 10/11), so programs such as
    /// vim can pick a light or dark scheme. Set from the active theme.
    public var reportedForeground = (red: UInt8(0xE5), green: UInt8(0xE5), blue: UInt8(0xE5))
    public var reportedBackground = (red: UInt8(0x1E), green: UInt8(0x1E), blue: UInt8(0x1E))

    /// Token sent to the remote side in `LC_ACCESSH_TOKEN`; a matching `hello` marks
    /// integration as verified.
    public var expectedIntegrationToken: String?
    /// When true, all shell-integration messages are ignored (per-host opt-out).
    public var isShellIntegrationDisabled = false {
        didSet {
            semantics.integration.status = isShellIntegrationDisabled ? .disabled : .notDetected
        }
    }
    /// Reply to ENQ. Empty by default (no reply), as modern terminals do.
    public var answerback = ""
    /// Character encoding of incoming bytes.
    public var usesLatin1: Bool {
        get { parser.isLatin1 }
        set { parser.isLatin1 = newValue }
    }

    var screens: [ScreenBuffer]
    var active = TerminalEmulator.primaryIndex
    var scrollback: [TerminalLine] = []
    /// Lines that have been dropped from the front of scrollback, ever. The absolute row of
    /// `scrollback[0]` equals this value.
    public internal(set) var evictedLineCount = 0
    var cursor = CursorState()
    var scrollTop = 0
    var scrollBottom: Int
    var tabStops: [Bool]
    var parser = VTParser()
    var hyperlinks: [UInt32: TerminalHyperlink] = [:]
    var hyperlinkIDs: [String: UInt32] = [:]
    var nextHyperlinkID: UInt32 = 1
    var lastPrintedScalar: Unicode.Scalar?
    var semantics = SemanticModel()
    var update = TerminalUpdate()
    let clock: () -> Date
    private var cursorBeforeFeed = (row: 0, column: 0)

    public init(columns: Int = 80, rows: Int = 24, scrollbackLimit: Int = 10_000, clock: @escaping () -> Date = Date.init) {
        let columns = min(max(columns, 2), Self.maximumColumns)
        let rows = min(max(rows, 1), Self.maximumRows)
        self.columns = columns
        self.rows = rows
        self.scrollbackLimit = max(0, scrollbackLimit)
        self.clock = clock
        scrollBottom = rows - 1
        let blank = ScreenBuffer(lines: Array(repeating: TerminalLine(columns: columns), count: rows), savedCursor: nil)
        screens = [blank, blank]
        tabStops = Self.defaultTabStops(columns: columns)
    }

    static func defaultTabStops(columns: Int) -> [Bool] {
        (0..<columns).map { $0 > 0 && $0 % 8 == 0 }
    }

    // MARK: - Input

    /// Processes bytes received from the remote side.
    @discardableResult
    public func feed<Bytes: Sequence>(_ bytes: Bytes) -> TerminalUpdate where Bytes.Element == UInt8 {
        cursorBeforeFeed = (cursor.row, cursor.column)
        var localParser = parser
        for byte in bytes {
            localParser.advance(byte, handler: self)
        }
        parser = localParser
        return finishUpdate()
    }

    /// Convenience for tests and local echo.
    @discardableResult
    public func feed(_ text: String) -> TerminalUpdate {
        feed(Array(text.utf8))
    }

    private func finishUpdate() -> TerminalUpdate {
        var result = update
        update = TerminalUpdate()
        result.isAlternateScreen = active == Self.alternateIndex
        result.cursorRow = cursor.row
        result.cursorColumn = cursor.column
        result.cursorMoved = cursorBeforeFeed != (cursor.row, cursor.column)
        if active == Self.primaryIndex {
            let row = screenOriginRow + cursor.row
            let range = logicalLineRange(containingAbsoluteRow: row)
            result.cursorLineText = text(ofAbsoluteRows: range.lowerBound..<(range.upperBound + 1))
            result.cursorLineKind = semantics.kind(of: TerminalPosition(row: range.lowerBound, column: 0))
            var offset = 0
            for absolute in range.lowerBound..<row {
                offset += line(atAbsoluteRow: absolute)?.cells.filter { $0.width != 0 }.count ?? 0
            }
            result.cursorLineOffset = offset + screenLine(cursor.row).characterOffset(forColumn: cursor.column)
        }
        let cursorLine = screenLine(cursor.row)
        let pastText = cursorLine.cells[cursor.column...].allSatisfy { $0.character == " " } && !cursorLine.isWrapped
        result.cursorCharacter = pastText ? nil : cursorLine.cells[cursor.column].character
        return result
    }

    // MARK: - Geometry

    /// Absolute row of screen row 0 on the primary screen.
    public var screenOriginRow: Int { evictedLineCount + scrollback.count }

    /// Oldest absolute row still available.
    public var firstAvailableRow: Int { evictedLineCount }

    /// One past the last absolute row (the bottom of the primary screen).
    public var endRow: Int { screenOriginRow + rows }

    public var isAlternateScreenActive: Bool { active == Self.alternateIndex }

    /// Number of lines currently held in scrollback.
    public var scrollbackCount: Int { scrollback.count }

    /// Cursor position on the active screen (0-based).
    public var cursorScreenPosition: (row: Int, column: Int) { (cursor.row, cursor.column) }

    /// Cursor position in absolute coordinates (meaningful on the primary screen).
    public var cursorPosition: TerminalPosition {
        TerminalPosition(row: screenOriginRow + cursor.row, column: cursor.column)
    }

    /// Resizes the terminal. Lines pushed off the top go to scrollback so absolute row
    /// numbers (and therefore semantic marks) stay valid; growing pulls them back.
    public func resize(columns newColumns: Int, rows newRows: Int) {
        let newColumns = min(max(newColumns, 2), Self.maximumColumns)
        let newRows = min(max(newRows, 1), Self.maximumRows)
        guard newColumns != columns || newRows != rows else { return }

        for index in screens.indices {
            var lines = screens[index].lines
            var cursorRow = index == active ? cursor.row : (screens[index].savedCursor?.cursor.row ?? 0)
            if newRows < lines.count {
                let excess = lines.count - newRows
                // Drop blank rows below the cursor first, then push rows above it off the top.
                var removedBelow = 0
                while removedBelow < excess, lines.count - 1 > cursorRow, lines.last?.isBlank == true {
                    lines.removeLast()
                    removedBelow += 1
                }
                let pushCount = excess - removedBelow
                if pushCount > 0 {
                    let pushed = lines.prefix(pushCount)
                    if index == Self.primaryIndex { scrollback.append(contentsOf: pushed) }
                    lines.removeFirst(pushCount)
                    cursorRow -= pushCount
                }
            } else if newRows > lines.count {
                var add = newRows - lines.count
                if index == Self.primaryIndex {
                    let pulled = min(add, scrollback.count)
                    if pulled > 0 {
                        lines.insert(contentsOf: scrollback.suffix(pulled), at: 0)
                        scrollback.removeLast(pulled)
                        cursorRow += pulled
                        add -= pulled
                    }
                }
                lines.append(contentsOf: Array(repeating: TerminalLine(columns: columns), count: add))
            }
            for row in lines.indices {
                lines[row] = Self.resizeLine(lines[row], to: newColumns)
            }
            screens[index].lines = lines
            if index == active {
                cursor.row = min(max(cursorRow, 0), newRows - 1)
            } else if screens[index].savedCursor != nil {
                screens[index].savedCursor?.cursor.row = min(max(cursorRow, 0), newRows - 1)
            }
        }

        columns = newColumns
        rows = newRows
        cursor.column = min(cursor.column, newColumns - 1)
        cursor.pendingWrap = false
        scrollTop = 0
        scrollBottom = newRows - 1
        let oldStops = tabStops
        tabStops = Self.defaultTabStops(columns: newColumns)
        for column in 0..<min(oldStops.count, newColumns) { tabStops[column] = oldStops[column] }
        trimScrollback(force: true)
        markAllRowsChanged()
    }

    static func resizeLine(_ line: TerminalLine, to columns: Int) -> TerminalLine {
        var line = line
        if line.cells.count > columns {
            line.cells.removeLast(line.cells.count - columns)
            if let last = line.cells.last, last.width == 2 {
                line.cells[columns - 1] = TerminalCell.blank(last.attributes.erased)
            }
        } else if line.cells.count < columns {
            let fill = line.cells.last?.attributes.erased ?? .default
            line.cells.append(contentsOf: Array(repeating: TerminalCell.blank(fill), count: columns - line.cells.count))
            line.isWrapped = false
        }
        return line
    }

    // MARK: - Scrollback

    func appendToScrollback(_ line: TerminalLine) {
        guard scrollbackLimit > 0 else {
            evictedLineCount += 1
            semantics.prune(before: evictedLineCount)
            return
        }
        scrollback.append(line)
        trimScrollback(force: false)
    }

    /// Trims in batches so appending stays amortized O(1).
    func trimScrollback(force: Bool) {
        let slack = force ? 0 : max(64, scrollbackLimit / 16)
        guard scrollback.count > scrollbackLimit + slack else { return }
        let excess = scrollback.count - scrollbackLimit
        scrollback.removeFirst(excess)
        evictedLineCount += excess
        semantics.prune(before: evictedLineCount)
    }

    // MARK: - Local clearing commands (not sent to the remote side)

    /// Clears the visible screen, keeping the line with the cursor (usually the prompt)
    /// at the top. Cleared rows move into scrollback, so they remain readable.
    public func clearScreen() {
        guard active == Self.primaryIndex else {
            eraseDisplay(mode: 2)
            update.events.append(.screenCleared)
            return
        }
        let keepFrom = logicalLineRange(containingAbsoluteRow: screenOriginRow + cursor.row).lowerBound - screenOriginRow
        let pushCount = max(0, keepFrom)
        for _ in 0..<pushCount {
            appendToScrollback(screens[active].lines.removeFirst())
            screens[active].lines.append(TerminalLine(columns: columns))
        }
        cursor.row -= pushCount
        markAllRowsChanged()
        update.events.append(.screenCleared)
    }

    /// Discards scrollback. The visible screen is unchanged.
    public func clearScrollback() {
        evictedLineCount += scrollback.count
        scrollback.removeAll()
        semantics.prune(before: evictedLineCount)
        update.events.append(.scrollbackCleared)
    }

    /// Discards scrollback and clears the screen except for the cursor line.
    public func clearScreenAndScrollback() {
        clearScreen()
        clearScrollback()
    }

    /// Returns events produced by local commands since the last feed.
    public func takePendingUpdate() -> TerminalUpdate { finishUpdate() }

    // MARK: - Snapshots and line access

    public func snapshot() -> TerminalScreenSnapshot {
        TerminalScreenSnapshot(
            columns: columns, rows: rows, lines: screens[active].lines,
            cursorRow: cursor.row, cursorColumn: cursor.column, modes: modes,
            isAlternateScreen: isAlternateScreenActive, title: title, screenOriginRow: screenOriginRow
        )
    }

    /// A row of the active screen.
    public func screenLine(_ row: Int) -> TerminalLine {
        screens[active].lines[min(max(row, 0), rows - 1)]
    }

    /// The active screen's rows.
    public var screenLines: [TerminalLine] { screens[active].lines }

    /// A primary-screen or scrollback row by absolute row number.
    public func line(atAbsoluteRow row: Int) -> TerminalLine? {
        if row < evictedLineCount { return nil }
        let index = row - evictedLineCount
        if index < scrollback.count { return scrollback[index] }
        let screenRow = index - scrollback.count
        guard screenRow < rows else { return nil }
        return screens[Self.primaryIndex].lines[screenRow]
    }

    public func hyperlink(id: UInt32) -> TerminalHyperlink? { hyperlinks[id] }

    // MARK: - Helpers used by the handlers

    func markRowChanged(_ row: Int) {
        update.changedRows.insert(row)
    }

    func markRowsChanged(_ rows: ClosedRange<Int>) {
        guard rows.lowerBound <= rows.upperBound else { return }
        update.changedRows.insert(integersIn: rows)
    }

    func markAllRowsChanged() {
        update.changedRows.insert(integersIn: 0..<rows)
    }

    func blankLine() -> TerminalLine {
        TerminalLine(columns: columns, attributes: cursor.attributes.erased)
    }
}
