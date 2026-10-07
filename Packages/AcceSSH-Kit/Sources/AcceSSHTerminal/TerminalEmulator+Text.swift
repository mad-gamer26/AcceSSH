import Foundation

// Text extraction over the primary screen and scrollback, in absolute coordinates.
extension TerminalEmulator {
    /// The absolute rows forming the logical line (soft-wrapped rows joined) that contains `row`.
    public func logicalLineRange(containingAbsoluteRow row: Int) -> ClosedRange<Int> {
        let first = firstAvailableRow, last = endRow - 1
        let row = min(max(row, first), last)
        var start = row
        while start > first, line(atAbsoluteRow: start - 1)?.isWrapped == true { start -= 1 }
        var end = row
        while end < last, line(atAbsoluteRow: end)?.isWrapped == true { end += 1 }
        return start...end
    }

    /// Text of absolute rows, joining wrapped rows and separating logical lines with "\n".
    public func text(ofAbsoluteRows rows: Range<Int>) -> String {
        let lower = max(rows.lowerBound, firstAvailableRow)
        let upper = min(rows.upperBound, endRow)
        guard lower < upper else { return "" }
        var result = ""
        for row in lower..<upper {
            guard let line = line(atAbsoluteRow: row) else { continue }
            let isLast = row == upper - 1
            result += line.text(trimmingTrailingSpaces: !line.isWrapped || isLast)
            if !line.isWrapped && !isLast { result += "\n" }
        }
        return result
    }

    /// Text between two absolute positions (`end` exclusive).
    public func text(from start: TerminalPosition, to end: TerminalPosition) -> String {
        guard start < end else { return "" }
        let first = max(start.row, firstAvailableRow)
        let last = min(end.row, endRow - 1)
        guard first <= last else { return "" }
        var result = ""
        for row in first...last {
            guard let line = line(atAbsoluteRow: row) else { continue }
            let from = row == start.row ? start.column : 0
            let to = row == end.row ? end.column : line.cells.count
            let isLastRow = row == last
            result += line.text(columns: from..<to, trimmingTrailingSpaces: !line.isWrapped || isLastRow)
            if !isLastRow && !line.isWrapped { result += "\n" }
        }
        return result
    }

    /// Text of the logical line at an absolute row.
    public func logicalLineText(atAbsoluteRow row: Int) -> String {
        let range = logicalLineRange(containingAbsoluteRow: row)
        return text(ofAbsoluteRows: range.lowerBound..<(range.upperBound + 1))
    }

    /// Text from the cursor to the end of its logical line.
    public func textFromCursor() -> String {
        if isAlternateScreenActive {
            return screenLine(cursor.row).text(columns: cursor.column..<columns, trimmingTrailingSpaces: true)
        }
        let range = logicalLineRange(containingAbsoluteRow: cursorPosition.row)
        return text(from: cursorPosition, to: TerminalPosition(row: range.upperBound + 1, column: 0))
    }

    /// Visible text of the active screen, rows separated by newlines, trailing blank rows dropped.
    public func visibleText() -> String {
        var lines = screenLines.map(\.text)
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    /// Plain text of all scrollback and the primary screen, for export.
    public func fullText() -> String {
        var text = text(ofAbsoluteRows: firstAvailableRow..<endRow)
        while text.hasSuffix("\n") { text.removeLast() }
        return text
    }

    /// Absolute rows whose text matches `query`.
    public func search(
        _ query: String, caseSensitive: Bool = false, regularExpression: Bool = false,
        in rows: Range<Int>? = nil
    ) throws -> [TerminalSearchMatch] {
        guard !query.isEmpty else { return [] }
        let range = rows ?? firstAvailableRow..<endRow
        var options: NSRegularExpression.Options = caseSensitive ? [] : [.caseInsensitive]
        if !regularExpression { options.insert(.ignoreMetacharacters) }
        let expression = try NSRegularExpression(pattern: query, options: options)
        var matches: [TerminalSearchMatch] = []
        var row = max(range.lowerBound, firstAvailableRow)
        while row < min(range.upperBound, endRow) {
            let logical = logicalLineRange(containingAbsoluteRow: row)
            let lineText = text(ofAbsoluteRows: logical.lowerBound..<(logical.upperBound + 1))
            let nsText = lineText as NSString
            for result in expression.matches(in: lineText, range: NSRange(location: 0, length: nsText.length)) where result.range.length > 0 {
                guard let swiftRange = Range(result.range, in: lineText) else { continue }
                let offset = lineText.distance(from: lineText.startIndex, to: swiftRange.lowerBound)
                matches.append(TerminalSearchMatch(
                    row: logical.lowerBound, lineText: lineText, characterOffset: offset,
                    matchedText: String(lineText[swiftRange])
                ))
            }
            row = logical.upperBound + 1
        }
        return matches
    }
}

/// One search hit.
public struct TerminalSearchMatch: Sendable, Equatable {
    /// Absolute row of the logical line containing the match.
    public var row: Int
    public var lineText: String
    /// Offset of the match within `lineText`, in Characters.
    public var characterOffset: Int
    public var matchedText: String
}
