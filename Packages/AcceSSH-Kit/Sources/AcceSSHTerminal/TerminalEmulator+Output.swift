import Foundation

// Printing, control characters, and screen-editing primitives.
extension TerminalEmulator: VTParserHandler {
    func vtPrint(_ input: Unicode.Scalar) {
        var scalar = input
        let charset = cursor.shiftOut ? cursor.g1 : cursor.g0
        if charset != .ascii, scalar.value < 0x80 { scalar = charset.map(scalar) }

        // Combining marks, ZWJ sequences, skin-tone modifiers, variation selectors and
        // regional-indicator pairs extend the previous cell's grapheme cluster.
        if scalar.value >= 0x300, joinWithPreviousCell(scalar) { return }

        let width = UnicodeWidth.width(of: scalar)
        if width == 0 { return }
        if width == 2 && columns < 2 { return }
        lastPrintedScalar = scalar

        if cursor.pendingWrap && modes.autoWrap {
            wrapToNextLine()
        }
        if width == 2 && cursor.column == columns - 1 {
            if modes.autoWrap {
                writeCells(TerminalCell.blank(cursor.attributes), width: 1, at: cursor.column)
                wrapToNextLine()
            } else {
                cursor.column = columns - 2
            }
        }
        if modes.insertMode {
            insertBlankCharacters(width)
        }
        let cell = TerminalCell(character: Character(scalar), width: UInt8(width), attributes: cursor.attributes, hyperlinkID: cursor.hyperlinkID)
        writeCells(cell, width: width, at: cursor.column)

        let next = cursor.column + width
        if next >= columns {
            cursor.column = columns - 1
            cursor.pendingWrap = modes.autoWrap
        } else {
            cursor.column = next
            cursor.pendingWrap = false
        }
    }

    private func joinWithPreviousCell(_ scalar: Unicode.Scalar) -> Bool {
        var column = cursor.pendingWrap ? cursor.column : cursor.column - 1
        guard column >= 0 else { return false }
        let row = cursor.row
        if screens[active].lines[row].cells[column].width == 0, column > 0 { column -= 1 }
        var combined = String(screens[active].lines[row].cells[column].character)
        combined.unicodeScalars.append(scalar)
        guard combined.count == 1, let character = combined.first else { return false }
        screens[active].lines[row].cells[column].character = character
        markRowChanged(row)
        return true
    }

    /// Writes a cell (and its continuation for wide characters), repairing any wide
    /// character that is partly overwritten.
    private func writeCells(_ cell: TerminalCell, width: Int, at column: Int) {
        let row = cursor.row
        clearWideFragments(row: row, column: column)
        if width == 2, column + 1 < columns { clearWideFragments(row: row, column: column + 1) }
        screens[active].lines[row].cells[column] = cell
        if width == 2, column + 1 < columns {
            var continuation = cell
            continuation.width = 0
            continuation.character = " "
            screens[active].lines[row].cells[column + 1] = continuation
        }
        markRowChanged(row)
    }

    private func clearWideFragments(row: Int, column: Int) {
        let cell = screens[active].lines[row].cells[column]
        if cell.width == 0, column > 0 {
            screens[active].lines[row].cells[column - 1] = TerminalCell.blank(cell.attributes.erased)
        } else if cell.width == 2, column + 1 < columns {
            screens[active].lines[row].cells[column + 1] = TerminalCell.blank(cell.attributes.erased)
        }
    }

    private func wrapToNextLine() {
        screens[active].lines[cursor.row].isWrapped = true
        cursor.pendingWrap = false
        cursor.column = 0
        index()
    }

    func vtExecute(_ control: UInt8) {
        switch control {
        case 0x05:
            if !answerback.isEmpty { update.responses.append(contentsOf: Array(answerback.utf8)) }
        case 0x07:
            update.events.append(.bell)
        case 0x08:
            cursor.pendingWrap = false
            if cursor.column > 0 { cursor.column -= 1 }
        case 0x09:
            tabForward(1)
        case 0x0A, 0x0B, 0x0C:
            lineFeed()
        case 0x0D:
            cursor.column = 0
            cursor.pendingWrap = false
        case 0x0E:
            cursor.shiftOut = true
        case 0x0F:
            cursor.shiftOut = false
        default:
            break
        }
    }

    // MARK: - Line feeds and scrolling

    func lineFeed() {
        commitCursorLine()
        index()
        if modes.newLineMode { cursor.column = 0 }
    }

    /// Records the logical line the cursor is leaving as committed output (primary screen).
    func commitCursorLine() {
        guard active == Self.primaryIndex else { return }
        // A row that wraps onto the next one is not finished yet.
        guard !screens[active].lines[cursor.row].isWrapped else { return }
        let absolute = screenOriginRow + cursor.row
        let range = logicalLineRange(containingAbsoluteRow: absolute)
        let start = TerminalPosition(row: range.lowerBound, column: 0)
        let text = text(ofAbsoluteRows: range.lowerBound..<(absolute + 1))
        update.committedLines.append(CommittedLine(
            text: text, row: range.lowerBound, kind: semantics.kind(of: start), commandID: semantics.commandID(containing: start)
        ))
    }

    /// IND: move down one row, scrolling the region at the bottom margin.
    func index() {
        cursor.pendingWrap = false
        if cursor.row == scrollBottom {
            scrollUp(1)
        } else if cursor.row < rows - 1 {
            cursor.row += 1
        }
    }

    /// RI: move up one row, scrolling the region down at the top margin.
    func reverseIndex() {
        cursor.pendingWrap = false
        if cursor.row == scrollTop {
            scrollDown(1)
        } else if cursor.row > 0 {
            cursor.row -= 1
        }
    }

    func scrollUp(_ count: Int) {
        let n = min(count, scrollBottom - scrollTop + 1)
        guard n > 0 else { return }
        // Only full-screen scrolls on the primary screen feed scrollback; this keeps
        // absolute row numbers stable for everything above and below a scroll region.
        let intoScrollback = active == Self.primaryIndex && scrollTop == 0 && scrollBottom == rows - 1
        let blank = blankLine()
        if intoScrollback {
            for line in screens[active].lines.prefix(n) { appendToScrollback(line) }
            screens[active].lines.removeFirst(n)
            screens[active].lines.append(contentsOf: Array(repeating: blank, count: n))
            update.scrolledLineCount += n
            markAllRowsChanged()
        } else {
            screens[active].lines.removeSubrange(scrollTop..<(scrollTop + n))
            screens[active].lines.insert(contentsOf: Array(repeating: blank, count: n), at: scrollBottom - n + 1)
            markRowsChanged(scrollTop...scrollBottom)
        }
    }

    func scrollDown(_ count: Int) {
        let n = min(count, scrollBottom - scrollTop + 1)
        guard n > 0 else { return }
        screens[active].lines.removeSubrange((scrollBottom - n + 1)...scrollBottom)
        screens[active].lines.insert(contentsOf: Array(repeating: blankLine(), count: n), at: scrollTop)
        markRowsChanged(scrollTop...scrollBottom)
    }

    // MARK: - Tabs

    func tabForward(_ count: Int) {
        cursor.pendingWrap = false
        for _ in 0..<count {
            var column = cursor.column + 1
            while column < columns - 1 && !tabStops[column] { column += 1 }
            cursor.column = min(column, columns - 1)
        }
    }

    func tabBackward(_ count: Int) {
        cursor.pendingWrap = false
        for _ in 0..<count {
            var column = cursor.column - 1
            while column > 0 && !tabStops[column] { column -= 1 }
            cursor.column = max(column, 0)
        }
    }

    // MARK: - Editing

    func insertBlankCharacters(_ count: Int) {
        let row = cursor.row
        let n = min(count, columns - cursor.column)
        guard n > 0 else { return }
        clearWideFragments(row: row, column: cursor.column)
        var cells = screens[active].lines[row].cells
        cells.removeLast(n)
        cells.insert(contentsOf: Array(repeating: TerminalCell.blank(cursor.attributes.erased), count: n), at: cursor.column)
        screens[active].lines[row].cells = cells
        cursor.pendingWrap = false
        markRowChanged(row)
    }

    func deleteCharacters(_ count: Int) {
        let row = cursor.row
        let n = min(count, columns - cursor.column)
        guard n > 0 else { return }
        clearWideFragments(row: row, column: cursor.column)
        var cells = screens[active].lines[row].cells
        cells.removeSubrange(cursor.column..<(cursor.column + n))
        cells.append(contentsOf: Array(repeating: TerminalCell.blank(cursor.attributes.erased), count: n))
        screens[active].lines[row].cells = cells
        screens[active].lines[row].isWrapped = false
        cursor.pendingWrap = false
        markRowChanged(row)
    }

    func eraseCharacters(_ count: Int) {
        let row = cursor.row
        let end = min(cursor.column + count, columns)
        guard cursor.column < end else { return }
        clearWideFragments(row: row, column: cursor.column)
        if end < columns { clearWideFragments(row: row, column: end) }
        let blank = TerminalCell.blank(cursor.attributes.erased)
        for column in cursor.column..<end { screens[active].lines[row].cells[column] = blank }
        cursor.pendingWrap = false
        markRowChanged(row)
    }

    func insertLines(_ count: Int) {
        guard cursor.row >= scrollTop, cursor.row <= scrollBottom else { return }
        let n = min(count, scrollBottom - cursor.row + 1)
        screens[active].lines.removeSubrange((scrollBottom - n + 1)...scrollBottom)
        screens[active].lines.insert(contentsOf: Array(repeating: blankLine(), count: n), at: cursor.row)
        cursor.column = 0
        cursor.pendingWrap = false
        markRowsChanged(cursor.row...scrollBottom)
    }

    func deleteLines(_ count: Int) {
        guard cursor.row >= scrollTop, cursor.row <= scrollBottom else { return }
        let n = min(count, scrollBottom - cursor.row + 1)
        screens[active].lines.removeSubrange(cursor.row..<(cursor.row + n))
        screens[active].lines.insert(contentsOf: Array(repeating: blankLine(), count: n), at: scrollBottom - n + 1)
        cursor.column = 0
        cursor.pendingWrap = false
        markRowsChanged(cursor.row...scrollBottom)
    }

    /// EL: 0 = cursor to end, 1 = start to cursor, 2 = whole line.
    func eraseLine(mode: Int) {
        let row = cursor.row
        let range: Range<Int>
        switch mode {
        case 0: range = cursor.column..<columns
        case 1: range = 0..<min(cursor.column + 1, columns)
        case 2: range = 0..<columns
        default: return
        }
        let blank = TerminalCell.blank(cursor.attributes.erased)
        if range.lowerBound > 0 { clearWideFragments(row: row, column: range.lowerBound) }
        if range.upperBound < columns { clearWideFragments(row: row, column: range.upperBound) }
        for column in range { screens[active].lines[row].cells[column] = blank }
        if mode != 1 { screens[active].lines[row].isWrapped = false }
        cursor.pendingWrap = false
        markRowChanged(row)
    }

    /// ED: 0 = cursor to end, 1 = start to cursor, 2 = whole screen, 3 = scrollback.
    func eraseDisplay(mode: Int) {
        switch mode {
        case 0:
            eraseLine(mode: 0)
            for row in (cursor.row + 1)..<rows where row < rows { screens[active].lines[row] = blankLine() }
            if cursor.row + 1 < rows { markRowsChanged((cursor.row + 1)...(rows - 1)) }
        case 1:
            eraseLine(mode: 1)
            for row in 0..<cursor.row { screens[active].lines[row] = blankLine() }
            if cursor.row > 0 { markRowsChanged(0...(cursor.row - 1)) }
        case 2:
            // On the primary screen, rows with content move into scrollback first (as VTE and
            // Terminal.app do), so output erased by `clear` can still be reviewed.
            if active == Self.primaryIndex {
                let lastContentRow = screens[active].lines.lastIndex { !$0.isBlank } ?? -1
                if lastContentRow >= 0 {
                    let count = lastContentRow + 1
                    for line in screens[active].lines.prefix(count) { appendToScrollback(line) }
                    screens[active].lines.removeFirst(count)
                    screens[active].lines.append(contentsOf: Array(repeating: blankLine(), count: count))
                }
            }
            for row in 0..<rows { screens[active].lines[row] = blankLine() }
            markAllRowsChanged()
            update.events.append(.screenCleared)
        case 3:
            clearScrollback()
        default:
            break
        }
        cursor.pendingWrap = false
    }

    // MARK: - Cursor

    func moveCursor(row: Int, column: Int) {
        cursor.row = min(max(row, 0), rows - 1)
        cursor.column = min(max(column, 0), columns - 1)
        cursor.pendingWrap = false
    }

    /// CUP with 1-based coordinates, honoring origin mode.
    func setCursorPosition(row oneBasedRow: Int, column oneBasedColumn: Int) {
        var row = oneBasedRow - 1
        if modes.originMode {
            row = min(max(row + scrollTop, scrollTop), scrollBottom)
        }
        moveCursor(row: row, column: oneBasedColumn - 1)
    }

    func saveCursor() {
        screens[active].savedCursor = SavedCursor(cursor: cursor, originMode: modes.originMode, autoWrap: modes.autoWrap)
    }

    func restoreCursor() {
        guard let saved = screens[active].savedCursor else {
            cursor = CursorState()
            modes.originMode = false
            return
        }
        cursor = saved.cursor
        cursor.row = min(cursor.row, rows - 1)
        cursor.column = min(cursor.column, columns - 1)
        modes.originMode = saved.originMode
        modes.autoWrap = saved.autoWrap
    }

    func setAlternateScreen(_ enabled: Bool, clear: Bool) {
        let target = enabled ? Self.alternateIndex : Self.primaryIndex
        guard target != active else { return }
        if enabled, clear {
            screens[Self.alternateIndex].lines = Array(repeating: TerminalLine(columns: columns), count: rows)
        }
        active = target
        cursor.pendingWrap = false
        markAllRowsChanged()
        update.events.append(.alternateScreenChanged(isActive: enabled))
    }

    // MARK: - Reset

    func softReset() {
        modes.insertMode = false
        modes.originMode = false
        modes.autoWrap = true
        modes.applicationCursorKeys = false
        modes.applicationKeypad = false
        modes.cursorVisible = true
        scrollTop = 0
        scrollBottom = rows - 1
        cursor.attributes = .default
        cursor.g0 = .ascii
        cursor.g1 = .ascii
        cursor.shiftOut = false
        cursor.pendingWrap = false
        screens[active].savedCursor = nil
    }

    func fullReset() {
        if active == Self.alternateIndex { setAlternateScreen(false, clear: false) }
        modes = TerminalModes()
        cursor = CursorState()
        scrollTop = 0
        scrollBottom = rows - 1
        tabStops = Self.defaultTabStops(columns: columns)
        screens[Self.primaryIndex].savedCursor = nil
        screens[Self.alternateIndex].savedCursor = nil
        for row in 0..<rows { screens[active].lines[row] = TerminalLine(columns: columns) }
        semantics.resetPhase()
        markAllRowsChanged()
        update.events.append(.reset)
    }
}
