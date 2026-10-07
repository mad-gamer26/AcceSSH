import Foundation

/// Keys the terminal knows how to encode. Printable text uses ``text(_:)``.
public enum TerminalKey: Codable, Hashable, Sendable {
    case text(String)
    case enter
    case tab
    case backspace
    case escape
    case up, down, left, right
    case home, end, pageUp, pageDown
    case insert, delete
    /// F1 through F20.
    case function(Int)

    /// Spoken name for labels, for example "Up Arrow" or "F5".
    public var spokenName: String {
        switch self {
        case let .text(text):
            switch text {
            case " ": "Space"
            default: text
            }
        case .enter: "Return"
        case .tab: "Tab"
        case .backspace: "Delete Backward"
        case .escape: "Escape"
        case .up: "Up Arrow"
        case .down: "Down Arrow"
        case .left: "Left Arrow"
        case .right: "Right Arrow"
        case .home: "Home"
        case .end: "End"
        case .pageUp: "Page Up"
        case .pageDown: "Page Down"
        case .insert: "Insert"
        case .delete: "Forward Delete"
        case let .function(n): "F\(n)"
        }
    }
}

public struct KeyModifiers: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let shift = KeyModifiers(rawValue: 1 << 0)
    public static let option = KeyModifiers(rawValue: 1 << 1)
    public static let control = KeyModifiers(rawValue: 1 << 2)
    public static let command = KeyModifiers(rawValue: 1 << 3)

    /// Spoken prefix in Apple's order, for example "Control Option".
    public var spokenName: String {
        var parts: [String] = []
        if contains(.control) { parts.append("Control") }
        if contains(.option) { parts.append("Option") }
        if contains(.shift) { parts.append("Shift") }
        if contains(.command) { parts.append("Command") }
        return parts.joined(separator: " ")
    }
}

/// A key plus modifiers.
public struct KeyChord: Codable, Hashable, Sendable {
    public var key: TerminalKey
    public var modifiers: KeyModifiers

    public init(_ key: TerminalKey, modifiers: KeyModifiers = []) {
        self.key = key
        self.modifiers = modifiers
    }

    public var spokenName: String {
        let mods = modifiers.spokenName
        return mods.isEmpty ? key.spokenName : "\(mods) \(key.spokenName)"
    }
}

/// Built-in commands that toolbar buttons, keyboard shortcuts and VoiceOver custom actions invoke.
public enum AppCommand: String, Codable, CaseIterable, Sendable {
    case readNewOutput
    case readCurrentLine
    case readFromCursor
    case readLastCommand
    case readLastCommandOutput
    case copyLastCommandOutput
    case selectLastCommandOutput
    case jumpToLastPrompt
    case jumpToPreviousPrompt
    case jumpToNextPrompt
    case jumpToPreviousCommand
    case jumpToNextCommand
    case jumpToPreviousError
    case jumpToNextError
    case repeatLastAnnouncement
    case toggleAutomaticSpeech
    case speakCursorPosition
    case describeScreen
    case clearScreen
    case clearScrollback
    case clearScreenAndScrollback
    case find
    case showCommandHistory
    case paste
    case newSession
    case duplicateSession
    case reconnect
    case disconnect

    public var displayName: String {
        switch self {
        case .readNewOutput: "Read New Output"
        case .readCurrentLine: "Read Current Line"
        case .readFromCursor: "Read From Cursor"
        case .readLastCommand: "Read Last Command"
        case .readLastCommandOutput: "Read Last Command Output"
        case .copyLastCommandOutput: "Copy Last Command Output"
        case .selectLastCommandOutput: "Select Last Command Output"
        case .jumpToLastPrompt: "Jump to Last Prompt"
        case .jumpToPreviousPrompt: "Jump to Previous Prompt"
        case .jumpToNextPrompt: "Jump to Next Prompt"
        case .jumpToPreviousCommand: "Jump to Previous Command"
        case .jumpToNextCommand: "Jump to Next Command"
        case .jumpToPreviousError: "Jump to Previous Error"
        case .jumpToNextError: "Jump to Next Error"
        case .repeatLastAnnouncement: "Repeat Last Announcement"
        case .toggleAutomaticSpeech: "Pause or Resume Automatic Speech"
        case .speakCursorPosition: "Speak Cursor Position"
        case .describeScreen: "Describe Screen"
        case .clearScreen: "Clear Screen"
        case .clearScrollback: "Clear Scrollback"
        case .clearScreenAndScrollback: "Clear Screen and Scrollback"
        case .find: "Find"
        case .showCommandHistory: "Command History"
        case .paste: "Paste"
        case .newSession: "New Session"
        case .duplicateSession: "Duplicate Session"
        case .reconnect: "Reconnect"
        case .disconnect: "Disconnect"
        }
    }
}

/// What a toolbar button or key mapping does.
public indirect enum KeyAction: Codable, Hashable, Sendable {
    case key(KeyChord)
    /// Literal text, sent as if typed.
    case text(String)
    /// Raw bytes, for custom escape sequences.
    case bytes([UInt8])
    /// A shell command, optionally followed by Return.
    case command(String, pressReturn: Bool)
    /// Several actions in order, with an optional pause between them in seconds.
    case macro([KeyAction], interval: TimeInterval)
    /// Latches a modifier for the next key (toolbar Control/Option buttons).
    case latchModifier(KeyModifiers)
    case app(AppCommand)
}

public struct ToolbarItem: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var action: KeyAction
    /// Short visible label, for example "Esc" or "^C".
    public var title: String
    /// Full name VoiceOver speaks, for example "Escape" or "Control C".
    public var accessibilityLabel: String
    public var accessibilityHint: String?
    /// SF Symbol name; text title is used when nil.
    public var symbolName: String?

    public init(
        id: UUID = UUID(), action: KeyAction, title: String, accessibilityLabel: String,
        accessibilityHint: String? = nil, symbolName: String? = nil
    ) {
        self.id = id
        self.action = action
        self.title = title
        self.accessibilityLabel = accessibilityLabel
        self.accessibilityHint = accessibilityHint
        self.symbolName = symbolName
    }

    public static func key(_ chord: KeyChord, title: String, label: String? = nil, symbol: String? = nil) -> ToolbarItem {
        ToolbarItem(action: .key(chord), title: title, accessibilityLabel: label ?? chord.spokenName, symbolName: symbol)
    }
}

/// An ordered set of toolbar buttons (a "toolbar profile").
public struct ToolbarProfile: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var items: [ToolbarItem]

    public init(id: UUID = UUID(), name: String, items: [ToolbarItem]) {
        self.id = id
        self.name = name
        self.items = items
    }

    public static let standardID = UUID(uuidString: "C7A0E1D2-0B6F-4E3A-9D1C-5A2B8E7F0001")!

    public static let standard = ToolbarProfile(id: standardID, name: "Standard", items: [
        .key(KeyChord(.escape), title: "Esc", label: "Escape"),
        .key(KeyChord(.tab), title: "Tab"),
        ToolbarItem(action: .latchModifier(.control), title: "Ctrl", accessibilityLabel: "Control",
                    accessibilityHint: "Applies Control to the next key you type."),
        ToolbarItem(action: .latchModifier(.option), title: "Alt", accessibilityLabel: "Option",
                    accessibilityHint: "Applies Option, also called Alt or Meta, to the next key you type."),
        .key(KeyChord(.up), title: "Up", symbol: "arrow.up"),
        .key(KeyChord(.down), title: "Down", symbol: "arrow.down"),
        .key(KeyChord(.left), title: "Left", symbol: "arrow.left"),
        .key(KeyChord(.right), title: "Right", symbol: "arrow.right"),
        .key(KeyChord(.text("c"), modifiers: .control), title: "^C", label: "Control C"),
        .key(KeyChord(.text("d"), modifiers: .control), title: "^D", label: "Control D"),
        .key(KeyChord(.text("z"), modifiers: .control), title: "^Z", label: "Control Z"),
        .key(KeyChord(.text("l"), modifiers: .control), title: "^L", label: "Control L"),
        .key(KeyChord(.home), title: "Home"),
        .key(KeyChord(.end), title: "End"),
        .key(KeyChord(.pageUp), title: "PgUp", label: "Page Up"),
        .key(KeyChord(.pageDown), title: "PgDn", label: "Page Down"),
        ToolbarItem(action: .app(.readNewOutput), title: "Read", accessibilityLabel: "Read New Output",
                    symbolName: "text.bubble"),
    ])
}

/// A remapping of a hardware key chord to an action.
public struct KeyMapping: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var trigger: KeyChord
    public var action: KeyAction

    public init(id: UUID = UUID(), trigger: KeyChord, action: KeyAction) {
        self.id = id
        self.trigger = trigger
        self.action = action
    }
}

/// How typed text reaches the server when a session opens.
public enum InputModePreference: String, Codable, CaseIterable, Sendable {
    /// Line editing at the shell prompt, direct keys in full-screen programs.
    case automatic
    /// A text field: compose a line with full VoiceOver editing, then send it with Return.
    case lineEditing
    /// Every key goes straight to the server.
    case directKeys

    public var displayName: String {
        switch self {
        case .automatic: "Automatic"
        case .lineEditing: "Line Editing"
        case .directKeys: "Direct Keys"
        }
    }
}

/// A three-finger swipe direction, as VoiceOver reports it.
public enum SwipeDirection: String, Codable, CaseIterable, Sendable, CodingKeyRepresentable {
    case up, down, left, right

    public var displayName: String {
        switch self {
        case .up: "Swipe Up"
        case .down: "Swipe Down"
        case .left: "Swipe Left"
        case .right: "Swipe Right"
        }
    }
}

/// What VoiceOver gestures do while focus is in the terminal.
public struct TerminalGestureSettings: Codable, Hashable, Sendable {
    /// Action for each three-finger swipe. A missing direction lets VoiceOver scroll the
    /// terminal as usual.
    public var threeFingerSwipes: [SwipeDirection: KeyAction]

    public init(threeFingerSwipes: [SwipeDirection: KeyAction]) {
        self.threeFingerSwipes = threeFingerSwipes
    }

    /// Default: each swipe sends the matching arrow key.
    public static let standard = TerminalGestureSettings(threeFingerSwipes: [
        .up: .key(KeyChord(.up)), .down: .key(KeyChord(.down)),
        .left: .key(KeyChord(.left)), .right: .key(KeyChord(.right)),
    ])
}

/// Hardware keyboard behavior (a "keyboard profile").
public struct KeyboardProfile: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    /// Treat Option as Meta (send ESC prefix) instead of typing special characters.
    public var optionSendsEscape: Bool
    /// Command-key shortcuts reach the app (copy, paste, new tab) instead of the terminal.
    public var commandShortcutsGoToApp: Bool
    public var mappings: [KeyMapping]
    /// Input mode for new sessions. `nil` means automatic (and keeps older saved profiles valid).
    public var defaultInputMode: InputModePreference?
    /// VoiceOver gestures in the terminal. `nil` means the standard mapping (arrow keys).
    public var gestures: TerminalGestureSettings?

    public var effectiveGestures: TerminalGestureSettings { gestures ?? .standard }

    public init(
        id: UUID = UUID(), name: String, optionSendsEscape: Bool = true,
        commandShortcutsGoToApp: Bool = true, mappings: [KeyMapping] = []
    ) {
        self.id = id
        self.name = name
        self.optionSendsEscape = optionSendsEscape
        self.commandShortcutsGoToApp = commandShortcutsGoToApp
        self.mappings = mappings
    }

    public func action(for chord: KeyChord) -> KeyAction? {
        mappings.first { $0.trigger == chord }?.action
    }

    public static let standardID = UUID(uuidString: "C7A0E1D2-0B6F-4E3A-9D1C-5A2B8E7F0002")!
    public static let standard = KeyboardProfile(id: standardID, name: "Standard")
}
