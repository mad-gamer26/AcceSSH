import Foundation

/// Terminal behavior settings (a "terminal profile").
public struct TerminalSettings: Codable, Hashable, Sendable {
    /// Value sent as `TERM` when requesting the PTY.
    public var terminalType: String
    public var scrollbackLines: Int
    public var characterEncoding: TerminalCharacterEncoding
    /// Wrap pasted text in bracketed-paste markers when the remote application enables it.
    public var allowBracketedPaste: Bool
    public var pasteConfirmation: PasteConfirmation
    /// Pastes longer than this many characters always ask for confirmation.
    public var largePasteThreshold: Int
    public var allowMouseReporting: Bool
    /// Send DEL (0x7F) for Backspace; when false send BS (0x08).
    public var backspaceSendsDelete: Bool
    /// Allow the remote side to set the window/tab title.
    public var allowTitleChanges: Bool
    /// Allow OSC 52 writes to the clipboard. Off by default: a remote program could
    /// otherwise replace clipboard contents without the person noticing.
    public var remoteClipboardWrite: RemoteClipboardPolicy
    /// Allow remote notifications (OSC 9 / OSC 777 / shell-integration notify).
    public var allowRemoteNotifications: Bool
    public var history: CommandHistorySettings
    public var sessionLog: SessionLogSettings

    public init(
        terminalType: String = "xterm-256color",
        scrollbackLines: Int = 10_000,
        characterEncoding: TerminalCharacterEncoding = .utf8,
        allowBracketedPaste: Bool = true,
        pasteConfirmation: PasteConfirmation = .whenMultiline,
        largePasteThreshold: Int = 2_000,
        allowMouseReporting: Bool = true,
        backspaceSendsDelete: Bool = true,
        allowTitleChanges: Bool = true,
        remoteClipboardWrite: RemoteClipboardPolicy = .ask,
        allowRemoteNotifications: Bool = true,
        history: CommandHistorySettings = CommandHistorySettings(),
        sessionLog: SessionLogSettings = SessionLogSettings()
    ) {
        self.terminalType = terminalType
        self.scrollbackLines = scrollbackLines
        self.characterEncoding = characterEncoding
        self.allowBracketedPaste = allowBracketedPaste
        self.pasteConfirmation = pasteConfirmation
        self.largePasteThreshold = largePasteThreshold
        self.allowMouseReporting = allowMouseReporting
        self.backspaceSendsDelete = backspaceSendsDelete
        self.allowTitleChanges = allowTitleChanges
        self.remoteClipboardWrite = remoteClipboardWrite
        self.allowRemoteNotifications = allowRemoteNotifications
        self.history = history
        self.sessionLog = sessionLog
    }
}

public enum TerminalCharacterEncoding: String, Codable, CaseIterable, Sendable {
    case utf8
    /// ISO 8859-1. Bytes are mapped 1:1 onto U+0000–U+00FF.
    case latin1
}

public enum PasteConfirmation: String, Codable, CaseIterable, Sendable {
    case always, whenMultiline, never
}

public enum RemoteClipboardPolicy: String, Codable, CaseIterable, Sendable {
    case deny, ask, allow
}

/// Privacy controls for command history kept by AcceSSH (separate from the remote
/// shell's own history file).
public struct CommandHistorySettings: Codable, Hashable, Sendable {
    public enum Retention: String, Codable, CaseIterable, Sendable {
        /// Keep nothing.
        case off
        /// Keep history in memory for the life of the session only.
        case session
        /// Save history on this device, per host.
        case persistent
    }

    public var retention: Retention
    public var maximumEntries: Int
    /// Do not record commands that begin with a space (matches `HISTCONTROL=ignorespace`).
    public var ignoreLeadingSpace: Bool
    /// Case-insensitive substrings that keep a command out of history, for example `password`.
    public var excludedSubstrings: [String]

    public init(
        retention: Retention = .session,
        maximumEntries: Int = 1_000,
        ignoreLeadingSpace: Bool = true,
        excludedSubstrings: [String] = ["password", "passwd", "secret", "token=", "api_key", "apikey"]
    ) {
        self.retention = retention
        self.maximumEntries = maximumEntries
        self.ignoreLeadingSpace = ignoreLeadingSpace
        self.excludedSubstrings = excludedSubstrings
    }

    /// Whether a command may be recorded under these settings. Text typed while the
    /// terminal is in secret-input mode never reaches this check: it is never recorded.
    public func allowsRecording(_ command: String) -> Bool {
        guard retention != .off else { return false }
        if command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
        if ignoreLeadingSpace, command.first == " " { return false }
        let lowered = command.lowercased()
        return !excludedSubstrings.contains { !$0.isEmpty && lowered.contains($0.lowercased()) }
    }
}

public struct SessionLogSettings: Codable, Hashable, Sendable {
    public var isEnabled: Bool
    public var includeTimestamps: Bool
    /// Write plain text instead of the raw byte stream.
    public var stripEscapeSequences: Bool
    /// Never write text typed while secret-input mode was active.
    public var redactSecretInput: Bool

    public init(
        isEnabled: Bool = false, includeTimestamps: Bool = true,
        stripEscapeSequences: Bool = true, redactSecretInput: Bool = true
    ) {
        self.isEnabled = isEnabled
        self.includeTimestamps = includeTimestamps
        self.stripEscapeSequences = stripEscapeSequences
        self.redactSecretInput = redactSecretInput
    }
}

/// Connection state of a session, shared by the UI, announcements and feedback.
public enum SessionConnectionState: Codable, Hashable, Sendable {
    case idle
    case connecting
    case verifyingHostKey
    case authenticating
    case connected
    case reconnecting(attempt: Int)
    case disconnected(reason: String?)
    case failed(message: String)

    /// Short phrase for status text and VoiceOver values, for example "Connected".
    public var spokenDescription: String {
        switch self {
        case .idle: "Not connected"
        case .connecting: "Connecting"
        case .verifyingHostKey: "Verifying host key"
        case .authenticating: "Authenticating"
        case .connected: "Connected"
        case let .reconnecting(attempt): "Reconnecting, attempt \(attempt)"
        case let .disconnected(reason): reason.map { "Disconnected: \($0)" } ?? "Disconnected"
        case let .failed(message): "Connection failed: \(message)"
        }
    }

    public var isActive: Bool {
        switch self {
        case .connecting, .verifyingHostKey, .authenticating, .connected, .reconnecting: true
        case .idle, .disconnected, .failed: false
        }
    }
}

/// The restorable description of an open session. Live state (the SSH connection and the
/// terminal emulator) is owned by `SessionManager` and is never persisted.
public struct SessionDescriptor: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var hostID: UUID
    public var title: String
    public var openedAt: Date

    public init(id: UUID = UUID(), hostID: UUID, title: String, openedAt: Date = Date()) {
        self.id = id
        self.hostID = hostID
        self.title = title
        self.openedAt = openedAt
    }
}
