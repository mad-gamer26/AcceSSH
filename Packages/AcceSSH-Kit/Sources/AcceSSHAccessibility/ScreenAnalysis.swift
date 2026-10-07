import Foundation
import AcceSSHCore
import AcceSSHTerminal

/// A run of visually highlighted cells (inverse video or a distinct background), which is
/// how curses menus, dialogs, `htop`, `mc` and `nano` mark the current selection.
public struct HighlightedSpan: Equatable, Sendable {
    public var row: Int
    public var columns: Range<Int>
    public var text: String
}

public enum HighlightDetector {
    /// Finds highlighted spans on a screen. A background shared by most of the screen (a
    /// themed application's base color) is not treated as highlighting.
    public static func spans(in lines: [TerminalLine], minimumCharacters: Int = 2) -> [HighlightedSpan] {
        let baseBackground = dominantBackground(lines)
        var spans: [HighlightedSpan] = []
        for (row, line) in lines.enumerated() {
            var start: Int?
            for column in 0...line.cells.count {
                let highlighted = column < line.cells.count && isHighlighted(line.cells[column].attributes, base: baseBackground)
                if highlighted, start == nil { start = column }
                if !highlighted, let begin = start {
                    let text = line.text(columns: begin..<column, trimmingTrailingSpaces: true)
                        .trimmingCharacters(in: .whitespaces)
                    if text.count >= minimumCharacters {
                        spans.append(HighlightedSpan(row: row, columns: begin..<column, text: text))
                    }
                    start = nil
                }
            }
        }
        return spans
    }

    private static func isHighlighted(_ attributes: CellAttributes, base: TerminalColor) -> Bool {
        if attributes.flags.contains(.inverse) { return true }
        return attributes.background != .default && attributes.background != base
    }

    private static func dominantBackground(_ lines: [TerminalLine]) -> TerminalColor {
        var counts: [TerminalColor: Int] = [:]
        var total = 0
        for line in lines {
            for cell in line.cells {
                counts[cell.attributes.background, default: 0] += 1
                total += 1
            }
        }
        guard let (color, count) = counts.max(by: { $0.value < $1.value }), total > 0,
              Double(count) / Double(total) > 0.5 else { return .default }
        return color
    }
}

/// Decides what to say when a full-screen application (alternate screen) redraws.
///
/// Rather than reading every changed row, the default reports what matters in menus and
/// editors: a newly highlighted item, or the cursor line when the cursor moves to a
/// different row or that row's text changes.
public struct AlternateScreenMonitor: Sendable {
    public var reading: AlternateScreenReading
    public var maximumChangedLines: Int

    private var previousHighlights: [HighlightedSpan] = []
    private var previousCursorRow = -1
    private var previousCursorColumn = -1
    private var previousCursorText = ""
    private var previousLines: [String] = []

    public init(reading: AlternateScreenReading, maximumChangedLines: Int = 6) {
        self.reading = reading
        self.maximumChangedLines = maximumChangedLines
    }

    /// Resets state, for example when an application enters the alternate screen.
    public mutating func reset() {
        previousHighlights = []
        previousCursorRow = -1
        previousCursorColumn = -1
        previousCursorText = ""
        previousLines = []
    }

    /// Compares a settled screen with the previous one and returns what to speak.
    public mutating func describeChanges(
        lines: [TerminalLine], cursorRow: Int, cursorColumn: Int = 0, settings: VoiceOverSettings
    ) -> SpeechUtterance? {
        let texts = lines.map(\.text)
        defer { previousLines = texts }
        switch reading {
        case .off:
            return nil
        case .changedLines:
            var changed: [String] = []
            for (row, text) in texts.enumerated() where row >= previousLines.count || previousLines[row] != text {
                let cleaned = SpeechTextFilter.clean(text, settings: settings)
                if !cleaned.isEmpty { changed.append(cleaned) }
            }
            guard !changed.isEmpty else { return nil }
            let shown = changed.prefix(maximumChangedLines).joined(separator: "\n")
            let extra = changed.count > maximumChangedLines ? "\n\(changed.count - maximumChangedLines) more changed lines." : ""
            return SpeechUtterance(shown + extra, kind: .screenChange)
        case .highlightAndCursorLine:
            let highlights = HighlightDetector.spans(in: lines)
            defer { previousHighlights = highlights }
            let new = highlights.filter { span in
                !previousHighlights.contains { $0.row == span.row && $0.text == span.text }
            }
            // A selection moving in a menu produces one new span; a redraw of the whole
            // screen produces many, and is better described by the cursor line.
            if !new.isEmpty, new.count <= 2, !previousHighlights.isEmpty || highlights.count <= 2 {
                previousCursorRow = cursorRow
                previousCursorText = texts.indices.contains(cursorRow) ? texts[cursorRow] : ""
                let text = new.map { SpeechTextFilter.clean($0.text, settings: settings) }.joined(separator: ", ")
                return text.isEmpty ? nil : SpeechUtterance(text, kind: .screenChange)
            }
            let cursorLine = lines.indices.contains(cursorRow) ? lines[cursorRow] : nil
            let cursorText = texts.indices.contains(cursorRow) ? texts[cursorRow] : ""
            defer {
                previousCursorRow = cursorRow
                previousCursorColumn = cursorColumn
                previousCursorText = cursorText
            }
            if cursorRow == previousCursorRow, cursorText == previousCursorText {
                guard cursorColumn != previousCursorColumn, let cursorLine, cursorColumn < cursorLine.cells.count else { return nil }
                // Typing a space at the end of the text leaves the (trimmed) text unchanged and
                // moves the cursor one place: say "space".
                if cursorColumn == previousCursorColumn + 1, previousCursorColumn >= 0,
                   cursorLine.characterOffset(forColumn: previousCursorColumn) >= cursorText.count {
                    return SpeechUtterance("space", kind: .completion)
                }
                // Otherwise it's cursor movement: say the character now under the cursor.
                let pastText = cursorLine.cells[cursorColumn...].allSatisfy { $0.character == " " }
                return SpeechUtterance(OutputSpeechScheduler.spokenCharacter(pastText ? nil : cursorLine.cells[cursorColumn].character),
                                       kind: .screenChange)
            }
            // Typing in an editor changes the same row: speak only what was inserted or
            // deleted rather than rereading the whole line on every keystroke.
            if cursorRow == previousCursorRow, !previousCursorText.isEmpty,
               let edit = Self.edit(from: previousCursorText, to: cursorText) {
                return SpeechUtterance(edit.text, kind: edit.isDeletion ? .deletion : .completion)
            }
            let cleaned = SpeechTextFilter.clean(cursorText, settings: settings)
            return SpeechUtterance(cleaned.isEmpty ? "Blank" : cleaned, kind: .screenChange)
        }
    }
}

extension AlternateScreenMonitor {
    /// A small in-place edit (at most 8 characters inserted or deleted, with the rest of the
    /// line unchanged), or `nil` if the line changed more than that.
    static func edit(from old: String, to new: String) -> (text: String, isDeletion: Bool)? {
        let prefix = zip(new, old).prefix { $0 == $1 }.count
        let newRest = new.dropFirst(prefix)
        let oldRest = old.dropFirst(prefix)
        let suffix = zip(newRest.reversed(), oldRest.reversed()).prefix { $0 == $1 }.count
        let inserted = String(newRest.dropLast(suffix))
        let removed = String(oldRest.dropLast(suffix))
        if !inserted.isEmpty, removed.isEmpty, inserted.count <= 8 {
            return (OutputSpeechScheduler.spokenTyping(inserted), false)
        }
        if inserted.isEmpty, !removed.isEmpty, removed.count <= 8 {
            return (OutputSpeechScheduler.spokenTyping(removed), true)
        }
        return nil
    }
}

/// Builds the "Describe Screen" summary.
public enum ScreenDescriber {
    public static func describe(_ terminal: TerminalEmulator) -> String {
        var sentences: [String] = []
        let (cursorRow, cursorColumn) = terminal.cursorScreenPosition
        if terminal.isAlternateScreenActive {
            sentences.append(terminal.title.isEmpty ? "Full-screen application." : "Full-screen application: \(terminal.title).")
        } else {
            sentences.append(terminal.title.isEmpty ? "Shell." : "Shell: \(terminal.title).")
        }
        sentences.append("\(terminal.rows) rows by \(terminal.columns) columns.")

        let lines = terminal.screenLines
        let nonBlank = lines.enumerated().filter { !$0.element.isBlank }
        sentences.append(nonBlank.isEmpty ? "The screen is empty." : "\(nonBlank.count) rows contain text.")

        if !terminal.isAlternateScreenActive {
            let state = terminal.shellIntegrationState
            if state.isAuthoritative, let last = terminal.lastExecutedCommand {
                var sentence = "Last command"
                if let line = last.commandLine { sentence += ": \(line)" }
                if let status = last.exitStatus {
                    sentence += status == 0 ? ", succeeded." : ", exit status \(status)."
                } else if last.phase == .running {
                    sentence += ", still running."
                } else {
                    sentence += "."
                }
                sentences.append(sentence)
            }
            if let directory = terminal.workingDirectory {
                sentences.append("Directory: \(directory).")
            }
        } else {
            let highlights = HighlightDetector.spans(in: lines)
            if let first = highlights.first(where: { $0.row == cursorRow }) ?? highlights.first {
                sentences.append("Highlighted: \(first.text).")
            }
            if let first = nonBlank.first {
                sentences.append("First line: \(first.element.text.trimmingCharacters(in: .whitespaces)).")
            }
            if let last = nonBlank.last, last.offset != nonBlank.first?.offset {
                sentences.append("Last line: \(last.element.text.trimmingCharacters(in: .whitespaces)).")
            }
        }
        sentences.append("Cursor on row \(cursorRow + 1), column \(cursorColumn + 1).")
        return sentences.joined(separator: " ")
    }
}
