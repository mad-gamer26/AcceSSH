import Foundation
import AcceSSHCore
import AcceSSHTerminal

/// Navigation over the semantic model, relative to a review position.
///
/// The review position is an absolute row the VoiceOver layer keeps separately from the
/// terminal cursor (like a screen reader's review cursor), so the person can explore
/// history without moving the shell's cursor.
public enum SemanticNavigator {
    public enum Direction: Sendable { case previous, next }

    /// The prompt before or after `row`.
    public static func prompt(_ direction: Direction, from row: Int, in terminal: TerminalEmulator) -> TerminalCommand? {
        let commands = terminal.commands.filter { $0.promptStart.row >= terminal.firstAvailableRow }
        switch direction {
        case .previous: return commands.last { $0.promptStart.row < row }
        case .next: return commands.first { $0.promptStart.row > row }
        }
    }

    /// The executed command before or after `row`.
    public static func command(_ direction: Direction, from row: Int, in terminal: TerminalEmulator) -> TerminalCommand? {
        let commands = terminal.commands.filter { $0.didExecute && $0.promptStart.row >= terminal.firstAvailableRow }
        switch direction {
        case .previous: return commands.last { $0.promptStart.row < row }
        case .next: return commands.first { $0.promptStart.row > row }
        }
    }

    /// The most recent prompt (normally the active one).
    public static func lastPrompt(in terminal: TerminalEmulator) -> TerminalCommand? {
        terminal.commands.last
    }

    /// The next or previous row whose logical line looks like an error. Rows inside the
    /// output of commands that failed are checked first when moving forward, so failures
    /// reported by shell integration take precedence over lexical matches.
    public static func errorRow(_ direction: Direction, from row: Int, in terminal: TerminalEmulator, limit: Int = 50_000) -> Int? {
        let first = terminal.firstAvailableRow
        let end = terminal.endRow
        var current = row
        var examined = 0
        while examined < limit {
            switch direction {
            case .next:
                current = terminal.logicalLineRange(containingAbsoluteRow: current).upperBound + 1
                guard current < end else { return nil }
            case .previous:
                current = terminal.logicalLineRange(containingAbsoluteRow: current).lowerBound - 1
                guard current >= first else { return nil }
                current = terminal.logicalLineRange(containingAbsoluteRow: current).lowerBound
            }
            examined += 1
            let kind = terminal.semanticKind(at: TerminalPosition(row: current, column: 0))
            guard kind == .output || kind == .unknown else { continue }
            if ErrorLineClassifier.classify(terminal.logicalLineText(atAbsoluteRow: current)) == .error {
                return current
            }
        }
        return nil
    }

    /// Text for "Read Last Command".
    public static func lastCommandDescription(in terminal: TerminalEmulator) -> String {
        guard let command = terminal.lastExecutedCommand else {
            return terminal.shellIntegrationState.isAuthoritative ? "No commands yet." : "No commands detected yet."
        }
        var text = command.commandLine ?? "Command text unavailable"
        switch (command.phase, command.exitStatus) {
        case (.running, _): text += ". Running."
        case (_, 0?): text += ". Succeeded."
        case let (_, status?): text += ". Exit status \(status)."
        default: break
        }
        return text
    }

    /// Text for "Read Last Command Output".
    public static func lastCommandOutput(in terminal: TerminalEmulator) -> String {
        guard let command = terminal.lastExecutedCommand else { return "No command output yet." }
        guard let output = terminal.outputText(of: command) else { return "That output is no longer in scrollback." }
        return output.isEmpty ? "The last command produced no output." : output
    }
}
