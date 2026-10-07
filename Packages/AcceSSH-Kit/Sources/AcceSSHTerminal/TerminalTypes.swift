import Foundation
import AcceSSHShellIntegration

public enum MouseTrackingMode: Sendable, Equatable {
    case off
    /// Mode 9: press only.
    case x10
    /// Mode 1000: press and release.
    case normal
    /// Mode 1002: plus motion while a button is down.
    case buttonEvent
    /// Mode 1003: all motion.
    case anyEvent
}

public enum MouseEncoding: Sendable, Equatable {
    case legacy, utf8, sgr, urxvt
}

/// Cursor style requested by the application with DECSCUSR (`CSI Ps SP q`).
public enum CursorStyleRequest: Int, Sendable, Equatable {
    case `default` = 0
    case blinkingBlock = 1
    case steadyBlock = 2
    case blinkingUnderline = 3
    case steadyUnderline = 4
    case blinkingBar = 5
    case steadyBar = 6
}

/// Terminal modes set by the remote application. Read-only to clients.
public struct TerminalModes: Equatable, Sendable {
    /// DECCKM: arrow keys send `ESC O x` instead of `ESC [ x`.
    public var applicationCursorKeys = false
    /// DECKPAM: keypad sends application sequences.
    public var applicationKeypad = false
    public var autoWrap = true
    public var originMode = false
    public var insertMode = false
    /// LNM: line feed also returns the carriage; Return sends CR LF.
    public var newLineMode = false
    public var cursorVisible = true
    public var cursorBlinking = false
    public var reverseVideo = false
    public var bracketedPaste = false
    public var focusReporting = false
    /// Mode 2026: the application is drawing a frame; render and speak after it ends.
    public var synchronizedOutput = false
    /// Mode 1007: scroll wheel sends arrow keys on the alternate screen.
    public var alternateScroll = false
    public var mouseTracking: MouseTrackingMode = .off
    public var mouseEncoding: MouseEncoding = .legacy
    public var cursorStyle: CursorStyleRequest = .default

    public init() {}
}

/// Semantic role of a line of output.
public enum LineSemanticKind: Sendable, Equatable {
    case prompt
    /// The command line the person typed (between prompt end and command execution).
    case commandInput
    case output
    /// No semantic information (no integration and no heuristic match).
    case unknown
}

/// A logical line that just ended with a line feed on the primary screen. Committed lines
/// are the authoritative "new output" stream for speech: they reflect the final contents
/// of the line (after carriage-return rewrites and in-line editing), not raw bytes.
public struct CommittedLine: Sendable, Equatable {
    public var text: String
    /// Absolute row of the line's first row.
    public var row: Int
    public var kind: LineSemanticKind
    public var commandID: UInt64?
}

/// Events produced while processing output.
public enum TerminalEvent: Sendable, Equatable {
    case bell
    case titleChanged(String)
    case workingDirectoryChanged(String)
    case alternateScreenChanged(isActive: Bool)
    case cursorStyleChanged(CursorStyleRequest)
    case applicationCursorKeysChanged(Bool)
    case synchronizedOutputChanged(Bool)
    case promptStarted(commandID: UInt64)
    case commandStarted(TerminalCommand)
    case commandFinished(TerminalCommand)
    case shellIntegrationChanged(ShellIntegrationState)
    case remoteNotification(title: String?, body: String, urgency: NotificationUrgency)
    /// OSC 52. The app applies `TerminalSettings.remoteClipboardWrite` before using it.
    case clipboardWriteRequested(String)
    case screenCleared
    case scrollbackCleared
    case reset
}

/// Everything that changed during one call to ``TerminalEmulator/feed(_:)``.
public struct TerminalUpdate: Sendable {
    public var events: [TerminalEvent] = []
    /// Bytes the terminal must send back to the remote side (device reports, query replies).
    public var responses: [UInt8] = []
    public var committedLines: [CommittedLine] = []
    /// Screen rows (0-based, of the active screen) whose contents changed.
    public var changedRows = IndexSet()
    /// Text of the logical line holding the cursor (primary screen only). For a shell this
    /// is the prompt plus whatever is typed after it.
    public var cursorLineText: String?
    public var cursorLineKind: LineSemanticKind = .unknown
    /// Characters before the cursor within ``cursorLineText`` (trailing spaces included).
    public var cursorLineOffset = 0
    /// The character under the cursor, or `nil` when the cursor is past the end of the text.
    public var cursorCharacter: Character?
    /// Cursor position on the active screen (0-based row and column).
    public var cursorRow = 0
    public var cursorColumn = 0
    public var cursorMoved = false
    public var isAlternateScreen = false
    /// Number of lines that scrolled off the top of the screen.
    public var scrolledLineCount = 0

    public init() {}

    public var hasVisibleChanges: Bool { !changedRows.isEmpty || !committedLines.isEmpty || cursorMoved }
}

/// A command and its output, as delimited by shell integration or heuristics.
public struct TerminalCommand: Identifiable, Sendable, Equatable {
    public enum Source: Sendable, Equatable {
        /// Boundaries reported by the shell (authoritative).
        case shellIntegration
        /// Boundaries guessed from prompt patterns and the Return key.
        case heuristic
    }

    public enum Phase: Sendable, Equatable {
        case prompt, input, running, finished
    }

    public let id: UInt64
    public var source: Source
    public var phase: Phase
    public var promptStart: TerminalPosition
    public var inputStart: TerminalPosition?
    public var outputStart: TerminalPosition?
    public var outputEnd: TerminalPosition?
    /// Exactly as reported by the shell, or extracted from the screen when not reported.
    public var commandLine: String?
    public var isCommandLineReported: Bool
    public var exitStatus: Int32?
    public var workingDirectory: String?
    public var startedAt: Date?
    public var finishedAt: Date?

    public init(
        id: UInt64, source: Source, phase: Phase, promptStart: TerminalPosition, inputStart: TerminalPosition?,
        outputStart: TerminalPosition?, outputEnd: TerminalPosition?, commandLine: String?, isCommandLineReported: Bool,
        exitStatus: Int32?, workingDirectory: String?, startedAt: Date?, finishedAt: Date?
    ) {
        self.id = id
        self.source = source
        self.phase = phase
        self.promptStart = promptStart
        self.inputStart = inputStart
        self.outputStart = outputStart
        self.outputEnd = outputEnd
        self.commandLine = commandLine
        self.isCommandLineReported = isCommandLineReported
        self.exitStatus = exitStatus
        self.workingDirectory = workingDirectory
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }

    public var duration: TimeInterval? {
        guard let startedAt, let finishedAt else { return nil }
        return finishedAt.timeIntervalSince(startedAt)
    }

    /// `true`/`false` once the exit status is known.
    public var succeeded: Bool? { exitStatus.map { $0 == 0 } }

    /// Whether a command was actually run (as opposed to an empty Return or Control-C at the prompt).
    public var didExecute: Bool { outputStart != nil }

    /// Absolute rows holding this command's output.
    public var outputRows: Range<Int>? {
        guard let start = outputStart else { return nil }
        guard let end = outputEnd else { return nil }
        let upper = end.column == 0 ? end.row : end.row + 1
        return start.row..<max(start.row, upper)
    }
}

/// A command's output range, for navigation by output block.
public struct TerminalOutputBlock: Sendable, Equatable, Identifiable {
    public var commandID: UInt64
    public var start: TerminalPosition
    public var end: TerminalPosition
    public var exitStatus: Int32?
    public var id: UInt64 { commandID }

    public init?(command: TerminalCommand) {
        guard let start = command.outputStart, let end = command.outputEnd else { return nil }
        commandID = command.id
        self.start = start
        self.end = end
        exitStatus = command.exitStatus
    }
}

/// An immutable copy of what the active screen shows, for renderers on another actor.
public struct TerminalScreenSnapshot: Sendable {
    public var columns: Int
    public var rows: Int
    public var lines: [TerminalLine]
    public var cursorRow: Int
    public var cursorColumn: Int
    public var modes: TerminalModes
    public var isAlternateScreen: Bool
    public var title: String
    /// Absolute row of screen row 0 (primary screen numbering).
    public var screenOriginRow: Int
}
