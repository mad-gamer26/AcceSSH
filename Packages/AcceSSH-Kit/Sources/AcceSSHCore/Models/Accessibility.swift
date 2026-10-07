import Foundation

/// How much terminal output AcceSSH speaks automatically.
public enum AutomaticReadingMode: String, Codable, CaseIterable, Sendable {
    /// New lines, prompts, completions, and changes on full-screen (alternate screen) apps.
    case speakEverything
    /// Each new complete line of output, then the prompt when it appears.
    case speakNewLines
    /// Only the prompt, once output settles.
    case speakPromptsOnly
    /// Only lines that look like errors, plus enabled event announcements.
    case speakImportantOnly
    /// Nothing automatically. Output accumulates for "Read New Output".
    case manual

    public var displayName: String {
        switch self {
        case .speakEverything: "Speak everything"
        case .speakNewLines: "Speak new lines"
        case .speakPromptsOnly: "Speak prompts only"
        case .speakImportantOnly: "Speak important messages only"
        case .manual: "Manual reading only"
        }
    }
}

/// What to do when more output arrives in one batch than ``VoiceOverSettings/maximumLinesPerAnnouncement``.
public enum OutputOverflowStrategy: String, Codable, CaseIterable, Sendable {
    /// Say how many lines arrived, then read the last lines (best for builds and logs).
    case speakLastLines
    /// Read the first lines, then say how many more arrived.
    case speakFirstLines
    /// Only say how many lines arrived.
    case summarize
}

/// How changes on the alternate screen (vim, htop, less, menus) are spoken.
public enum AlternateScreenReading: String, Codable, CaseIterable, Sendable {
    /// Speak newly highlighted items (menu selections) and the cursor line when it changes.
    case highlightAndCursorLine
    /// Speak every changed row (verbose).
    case changedLines
    /// Speak nothing automatically on the alternate screen.
    case off
}

public enum PromptReading: String, Codable, CaseIterable, Sendable {
    /// Speak the prompt text, for example "matt@server:~$".
    case fullText
    /// Speak "Prompt" (or the configured phrase) without the prompt text.
    case announceOnly
    case off
}

/// Independently switchable classes of announcements.
public enum AnnouncementCategory: String, Codable, CaseIterable, Sendable, CodingKeyRepresentable {
    case connection
    case authentication
    case hostKey
    case errors
    case prompts
    case commandCompletion
    case commandFailure
    case bell
    case remoteNotifications
    case backgroundSessionActivity
    case fileTransfer
    case portForwarding
    case shellIntegration
    case cursor

    public var displayName: String {
        switch self {
        case .connection: "Connection changes"
        case .authentication: "Authentication"
        case .hostKey: "Host key warnings"
        case .errors: "Errors"
        case .prompts: "Prompts"
        case .commandCompletion: "Command completion"
        case .commandFailure: "Command failure"
        case .bell: "Terminal bell"
        case .remoteNotifications: "Remote notifications"
        case .backgroundSessionActivity: "Activity in other sessions"
        case .fileTransfer: "File transfers"
        case .portForwarding: "Port forwarding"
        case .shellIntegration: "Shell integration status"
        case .cursor: "Cursor movement"
        }
    }
}

/// Granular cursor announcements; all off by default to avoid chatter.
public struct CursorAnnouncementSettings: Codable, Hashable, Sendable {
    public var speakCharacterUnderCursor: Bool
    public var speakRowAndColumn: Bool
    public var speakLineOnVerticalMove: Bool
    public var speakApplicationCursorModeChanges: Bool

    public init(
        speakCharacterUnderCursor: Bool = false, speakRowAndColumn: Bool = false,
        speakLineOnVerticalMove: Bool = false, speakApplicationCursorModeChanges: Bool = false
    ) {
        self.speakCharacterUnderCursor = speakCharacterUnderCursor
        self.speakRowAndColumn = speakRowAndColumn
        self.speakLineOnVerticalMove = speakLineOnVerticalMove
        self.speakApplicationCursorModeChanges = speakApplicationCursorModeChanges
    }
}

/// How terminal text is divided into accessibility elements.
public enum TerminalElementGranularity: String, Codable, CaseIterable, Sendable {
    /// One element per logical line (wrapped rows joined). Recommended.
    case logicalLines
    /// One element per visual row, matching the screen exactly.
    case visualRows
    /// One element per command output block when shell integration is active, else logical lines.
    case outputBlocks
}

public struct VoiceOverSettings: Codable, Hashable, Sendable {
    public var automaticReading: AutomaticReadingMode
    /// Quiet period (seconds) before batched output is spoken.
    public var coalescingInterval: TimeInterval
    /// Longest time (seconds) output may wait during a continuous stream before something is spoken.
    public var maximumLatency: TimeInterval
    public var maximumLinesPerAnnouncement: Int
    public var maximumCharactersPerAnnouncement: Int
    public var overflowStrategy: OutputOverflowStrategy
    public var promptReading: PromptReading
    /// Don't speak the echo of a command the person just typed.
    public var suppressCommandEcho: Bool
    /// Speak text the shell inserts that the person did not type (tab completion, history recall).
    public var speakInsertedCompletions: Bool
    /// Speak characters the remote side removes from the command line.
    public var speakDeletedCharacters: Bool
    public var skipBoxDrawingCharacters: Bool
    /// Replace runs of 4+ identical symbols (------, =====) with a single space.
    public var collapseRepeatedSymbols: Bool
    /// Wait for synchronized-output (mode 2026) frames to finish before speaking.
    public var respectSynchronizedOutput: Bool
    public var alternateScreenReading: AlternateScreenReading
    public var enabledAnnouncements: Set<AnnouncementCategory>
    public var announceSuccessfulCommands: Bool
    public var announceFailedCommands: Bool
    /// Include the exit status number in failure announcements.
    public var includeExitStatus: Bool
    /// Include the command name ("make finished with exit status 2").
    public var includeCommandInCompletion: Bool
    /// Announce completion of any command that ran at least this long, even if successful. `nil` disables.
    public var longRunningCommandThreshold: TimeInterval?
    public var cursor: CursorAnnouncementSettings
    public var elementGranularity: TerminalElementGranularity
    /// Phrase spoken for `PromptReading.announceOnly`.
    public var promptPhrase: String

    public init(
        automaticReading: AutomaticReadingMode = .speakNewLines,
        coalescingInterval: TimeInterval = 0.3,
        maximumLatency: TimeInterval = 1.5,
        maximumLinesPerAnnouncement: Int = 12,
        maximumCharactersPerAnnouncement: Int = 1_200,
        overflowStrategy: OutputOverflowStrategy = .speakLastLines,
        promptReading: PromptReading = .fullText,
        suppressCommandEcho: Bool = true,
        speakInsertedCompletions: Bool = true,
        speakDeletedCharacters: Bool = true,
        skipBoxDrawingCharacters: Bool = true,
        collapseRepeatedSymbols: Bool = true,
        respectSynchronizedOutput: Bool = true,
        alternateScreenReading: AlternateScreenReading = .highlightAndCursorLine,
        enabledAnnouncements: Set<AnnouncementCategory> = VoiceOverSettings.defaultAnnouncements,
        announceSuccessfulCommands: Bool = false,
        announceFailedCommands: Bool = true,
        includeExitStatus: Bool = true,
        includeCommandInCompletion: Bool = false,
        longRunningCommandThreshold: TimeInterval? = 10,
        cursor: CursorAnnouncementSettings = CursorAnnouncementSettings(),
        elementGranularity: TerminalElementGranularity = .logicalLines,
        promptPhrase: String = "Prompt"
    ) {
        self.automaticReading = automaticReading
        self.coalescingInterval = coalescingInterval
        self.maximumLatency = maximumLatency
        self.maximumLinesPerAnnouncement = maximumLinesPerAnnouncement
        self.maximumCharactersPerAnnouncement = maximumCharactersPerAnnouncement
        self.overflowStrategy = overflowStrategy
        self.promptReading = promptReading
        self.suppressCommandEcho = suppressCommandEcho
        self.speakInsertedCompletions = speakInsertedCompletions
        self.speakDeletedCharacters = speakDeletedCharacters
        self.skipBoxDrawingCharacters = skipBoxDrawingCharacters
        self.collapseRepeatedSymbols = collapseRepeatedSymbols
        self.respectSynchronizedOutput = respectSynchronizedOutput
        self.alternateScreenReading = alternateScreenReading
        self.enabledAnnouncements = enabledAnnouncements
        self.announceSuccessfulCommands = announceSuccessfulCommands
        self.announceFailedCommands = announceFailedCommands
        self.includeExitStatus = includeExitStatus
        self.includeCommandInCompletion = includeCommandInCompletion
        self.longRunningCommandThreshold = longRunningCommandThreshold
        self.cursor = cursor
        self.elementGranularity = elementGranularity
        self.promptPhrase = promptPhrase
    }

    /// Quiet by default: connection, auth, host key, errors, failures and remote notifications.
    public static let defaultAnnouncements: Set<AnnouncementCategory> = [
        .connection, .authentication, .hostKey, .errors, .commandFailure, .commandCompletion,
        .remoteNotifications, .fileTransfer, .portForwarding, .shellIntegration,
    ]

    public func isEnabled(_ category: AnnouncementCategory) -> Bool {
        enabledAnnouncements.contains(category)
    }
}

/// Accessibility settings (an "accessibility profile").
public struct AccessibilitySettings: Codable, Hashable, Sendable {
    public var voiceOver: VoiceOverSettings
    /// Use a high-contrast theme regardless of the profile's theme.
    public var forceHighContrast: Bool
    /// Follow the system Increase Contrast setting by switching to high-contrast themes.
    public var followSystemIncreaseContrast: Bool
    public var boldTerminalText: Bool
    /// Thicker cursor with an outline, visible on any background.
    public var enhancedCursorVisibility: Bool
    /// Underline or otherwise mark colored text so meaning never depends on color alone.
    public var differentiateWithoutColor: Bool
    /// Flash and blink effects are disabled when Reduce Motion is on or this is true.
    public var reduceMotion: Bool
    /// Warn before pasting into the terminal when VoiceOver is running, even for single lines.
    public var confirmPasteWithVoiceOver: Bool

    public init(
        voiceOver: VoiceOverSettings = VoiceOverSettings(),
        forceHighContrast: Bool = false,
        followSystemIncreaseContrast: Bool = true,
        boldTerminalText: Bool = false,
        enhancedCursorVisibility: Bool = false,
        differentiateWithoutColor: Bool = false,
        reduceMotion: Bool = false,
        confirmPasteWithVoiceOver: Bool = false
    ) {
        self.voiceOver = voiceOver
        self.forceHighContrast = forceHighContrast
        self.followSystemIncreaseContrast = followSystemIncreaseContrast
        self.boldTerminalText = boldTerminalText
        self.enhancedCursorVisibility = enhancedCursorVisibility
        self.differentiateWithoutColor = differentiateWithoutColor
        self.reduceMotion = reduceMotion
        self.confirmPasteWithVoiceOver = confirmPasteWithVoiceOver
    }
}
