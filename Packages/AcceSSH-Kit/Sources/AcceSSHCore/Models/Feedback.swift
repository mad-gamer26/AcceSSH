import Foundation

/// Every application event that can produce sound, haptics, speech or a visual signal.
public enum FeedbackEvent: String, Codable, CaseIterable, Sendable, CodingKeyRepresentable {
    case connected
    case disconnected
    case reconnecting
    case connectionFailed
    case authenticationRequired
    case authenticationSucceeded
    case authenticationFailed
    case hostKeyWarning
    case terminalBell
    case backgroundActivity
    case fileTransferCompleted
    case fileTransferFailed
    case portForwardingFailed
    case commandCompleted
    case commandFailed
    case remoteNotification
    case promptReady

    public var displayName: String {
        switch self {
        case .connected: "Connected"
        case .disconnected: "Disconnected"
        case .reconnecting: "Reconnecting"
        case .connectionFailed: "Connection failed"
        case .authenticationRequired: "Authentication required"
        case .authenticationSucceeded: "Authentication succeeded"
        case .authenticationFailed: "Authentication failed"
        case .hostKeyWarning: "Host key warning"
        case .terminalBell: "Terminal bell"
        case .backgroundActivity: "Activity in another session"
        case .fileTransferCompleted: "File transfer complete"
        case .fileTransferFailed: "File transfer failed"
        case .portForwardingFailed: "Port forwarding failed"
        case .commandCompleted: "Command completed"
        case .commandFailed: "Command failed"
        case .remoteNotification: "Remote notification"
        case .promptReady: "Prompt ready"
        }
    }
}

/// A synthesized tone, rendered with AVAudioEngine so no audio files are required.
public struct ToneSpec: Codable, Hashable, Sendable {
    public enum Waveform: String, Codable, CaseIterable, Sendable { case sine, triangle, square }

    /// Frequency in hertz (clamped 100–4000 when played).
    public var frequency: Double
    /// Duration in seconds (clamped 0.02–2 when played).
    public var duration: Double
    public var waveform: Waveform
    /// A second tone played immediately after, for two-note cues. `nil` for a single note.
    public var secondFrequency: Double?

    public init(frequency: Double, duration: Double, waveform: Waveform = .sine, secondFrequency: Double? = nil) {
        self.frequency = frequency
        self.duration = duration
        self.waveform = waveform
        self.secondFrequency = secondFrequency
    }
}

public enum SoundSource: Codable, Hashable, Sendable {
    case none
    /// A sound shipped in the app bundle, by resource name.
    case bundled(name: String)
    /// A sound file the person imported into the app container, by file name.
    case custom(fileName: String)
    case tone(ToneSpec)
    /// The platform alert sound (NSSound.beep on macOS; a short system sound on iOS).
    case systemAlert
}

/// A Core Haptics–style pattern. Played only on hardware that reports haptic support;
/// otherwise the closest basic feedback (or nothing) is used.
public struct HapticPattern: Codable, Hashable, Sendable {
    public struct Event: Codable, Hashable, Sendable {
        public enum Kind: String, Codable, Sendable { case transient, continuous }
        public var kind: Kind
        public var time: TimeInterval
        /// Only used by continuous events.
        public var duration: TimeInterval
        /// 0...1
        public var intensity: Double
        /// 0...1
        public var sharpness: Double

        public init(kind: Kind, time: TimeInterval, duration: TimeInterval = 0, intensity: Double, sharpness: Double) {
            self.kind = kind
            self.time = time
            self.duration = duration
            self.intensity = intensity
            self.sharpness = sharpness
        }
    }

    public var events: [Event]
    public init(events: [Event]) { self.events = events }

    public static let doubleTap = HapticPattern(events: [
        Event(kind: .transient, time: 0, intensity: 0.8, sharpness: 0.6),
        Event(kind: .transient, time: 0.12, intensity: 0.8, sharpness: 0.6),
    ])
    public static let longBuzz = HapticPattern(events: [
        Event(kind: .continuous, time: 0, duration: 0.4, intensity: 1, sharpness: 0.3),
    ])
}

public enum HapticStyle: Codable, Hashable, Sendable {
    case none
    case light, medium, heavy, soft, rigid
    case success, warning, error
    case selection
    case custom(HapticPattern)
}

public enum VisualFeedback: String, Codable, CaseIterable, Sendable {
    case none
    /// Brief flash of the whole terminal. Suppressed under Reduce Motion (border is used instead).
    case flashScreen
    /// Brief highlight of the terminal border; safe under Reduce Motion.
    case flashBorder
}

/// Sounds assigned to events (a "sound profile").
public struct SoundProfile: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    /// 0...1, applied on top of the system volume. iOS never lets apps exceed the system volume.
    public var volume: Double
    public var sounds: [FeedbackEvent: SoundSource]

    public init(id: UUID = UUID(), name: String, volume: Double = 0.6, sounds: [FeedbackEvent: SoundSource]) {
        self.id = id
        self.name = name
        self.volume = volume
        self.sounds = sounds
    }

    public func sound(for event: FeedbackEvent) -> SoundSource { sounds[event] ?? .none }

    public static let quietID = UUID(uuidString: "4B0C6A5E-1D0A-4B2E-8E7B-2F6C5A9D0001")!
    /// Default: silent except connection loss and failures, so the app is not noisy.
    public static let quiet = SoundProfile(id: quietID, name: "Quiet", sounds: [
        .disconnected: .tone(ToneSpec(frequency: 660, duration: 0.09, secondFrequency: 440)),
        .connectionFailed: .tone(ToneSpec(frequency: 440, duration: 0.12, secondFrequency: 330)),
        .authenticationFailed: .tone(ToneSpec(frequency: 440, duration: 0.12, secondFrequency: 330)),
        .hostKeyWarning: .tone(ToneSpec(frequency: 880, duration: 0.15, waveform: .triangle, secondFrequency: 440)),
    ])
}

/// Haptics assigned to events (a "haptic profile").
public struct HapticProfile: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var haptics: [FeedbackEvent: HapticStyle]

    public init(id: UUID = UUID(), name: String, haptics: [FeedbackEvent: HapticStyle]) {
        self.id = id
        self.name = name
        self.haptics = haptics
    }

    public func haptic(for event: FeedbackEvent) -> HapticStyle { haptics[event] ?? .none }

    public static let standardID = UUID(uuidString: "4B0C6A5E-1D0A-4B2E-8E7B-2F6C5A9D0002")!
    public static let standard = HapticProfile(id: standardID, name: "Standard", haptics: [
        .connected: .success,
        .disconnected: .warning,
        .connectionFailed: .error,
        .authenticationFailed: .error,
        .hostKeyWarning: .error,
        .commandFailed: .light,
    ])
}

/// Hours during which bells (and optionally other sounds) are silenced.
public struct QuietHours: Codable, Hashable, Sendable {
    /// Minutes after midnight, local time.
    public var startMinute: Int
    public var endMinute: Int
    public var allowHaptics: Bool

    public init(startMinute: Int, endMinute: Int, allowHaptics: Bool = true) {
        self.startMinute = startMinute
        self.endMinute = endMinute
        self.allowHaptics = allowHaptics
    }

    /// Whether `date` falls inside the window; windows may wrap past midnight.
    public func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        if startMinute == endMinute { return false }
        if startMinute < endMinute { return minute >= startMinute && minute < endMinute }
        return minute >= startMinute || minute < endMinute
    }
}

public enum BackgroundBellBehavior: String, Codable, CaseIterable, Sendable {
    case ignore
    /// Post a local notification (requires notification permission).
    case notify
}

/// Response to ASCII BEL (a "bell profile"). Every channel is independent.
public struct BellProfile: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var sound: SoundSource
    public var volume: Double
    public var haptic: HapticStyle
    public var visual: VisualFeedback
    /// Spoken through a VoiceOver announcement when VoiceOver is running. `nil` = silent.
    public var spokenPhrase: String?
    /// Minimum seconds between bell responses; extra bells inside the window are dropped.
    public var throttleInterval: TimeInterval
    public var quietHours: QuietHours?
    public var background: BackgroundBellBehavior

    public init(
        id: UUID = UUID(), name: String, sound: SoundSource = .none, volume: Double = 0.6,
        haptic: HapticStyle = .none, visual: VisualFeedback = .none, spokenPhrase: String? = nil,
        throttleInterval: TimeInterval = 0.5, quietHours: QuietHours? = nil,
        background: BackgroundBellBehavior = .ignore
    ) {
        self.id = id
        self.name = name
        self.sound = sound
        self.volume = volume
        self.haptic = haptic
        self.visual = visual
        self.spokenPhrase = spokenPhrase
        self.throttleInterval = throttleInterval
        self.quietHours = quietHours
        self.background = background
    }
}

extension BellProfile {
    public static let silentID = UUID(uuidString: "9E3D1B7A-58C4-4F9B-A7E2-3C1D2B4A0001")!
    public static let subtleID = UUID(uuidString: "9E3D1B7A-58C4-4F9B-A7E2-3C1D2B4A0002")!
    public static let classicID = UUID(uuidString: "9E3D1B7A-58C4-4F9B-A7E2-3C1D2B4A0003")!
    public static let hapticOnlyID = UUID(uuidString: "9E3D1B7A-58C4-4F9B-A7E2-3C1D2B4A0004")!
    public static let spokenID = UUID(uuidString: "9E3D1B7A-58C4-4F9B-A7E2-3C1D2B4A0005")!
    public static let strongAlertID = UUID(uuidString: "9E3D1B7A-58C4-4F9B-A7E2-3C1D2B4A0006")!

    public static let silent = BellProfile(id: silentID, name: "Silent")
    public static let subtle = BellProfile(
        id: subtleID, name: "Subtle",
        sound: .tone(ToneSpec(frequency: 1_320, duration: 0.04)), volume: 0.3, haptic: .light
    )
    public static let classic = BellProfile(
        id: classicID, name: "Classic Terminal",
        sound: .tone(ToneSpec(frequency: 880, duration: 0.12, waveform: .square)), volume: 0.5,
        visual: .flashBorder
    )
    public static let hapticOnly = BellProfile(id: hapticOnlyID, name: "Haptic Only", haptic: .medium)
    public static let spoken = BellProfile(id: spokenID, name: "Spoken Bell", spokenPhrase: "Bell")
    public static let strongAlert = BellProfile(
        id: strongAlertID, name: "Strong Alert",
        sound: .tone(ToneSpec(frequency: 988, duration: 0.15, waveform: .square, secondFrequency: 1_319)),
        volume: 0.9, haptic: .custom(.doubleTap), visual: .flashScreen, spokenPhrase: "Bell",
        throttleInterval: 1, background: .notify
    )

    public static let presets: [BellProfile] = [silent, subtle, classic, hapticOnly, spoken, strongAlert]

    /// Default is Subtle: audible and felt, never intrusive.
    public static let `default` = subtle
}
