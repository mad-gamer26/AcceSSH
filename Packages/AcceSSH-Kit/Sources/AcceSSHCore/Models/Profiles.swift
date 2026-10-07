import Foundation

/// A named, reusable settings value that hosts can reference by `id`.
public struct NamedProfile<Settings: Codable & Hashable & Sendable>: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var settings: Settings

    public init(id: UUID = UUID(), name: String, settings: Settings) {
        self.id = id
        self.name = name
        self.settings = settings
    }
}

public typealias AppearanceProfile = NamedProfile<AppearanceSettings>
public typealias TerminalProfile = NamedProfile<TerminalSettings>
public typealias AccessibilityProfile = NamedProfile<AccessibilitySettings>

/// Every profile library plus the global defaults. Persisted by `SettingsStore`.
public struct ProfileLibrary: Codable, Hashable, Sendable {
    public var appearance: [AppearanceProfile]
    public var terminal: [TerminalProfile]
    public var accessibility: [AccessibilityProfile]
    public var keyboard: [KeyboardProfile]
    public var toolbar: [ToolbarProfile]
    public var sound: [SoundProfile]
    public var haptic: [HapticProfile]
    public var bell: [BellProfile]
    public var themes: [TerminalTheme]
    public var defaults: HostProfileReferences

    public static let defaultAppearanceID = UUID(uuidString: "0D7E2C4B-8F31-4A69-B5D0-1E9C3A7F0001")!
    public static let defaultTerminalID = UUID(uuidString: "0D7E2C4B-8F31-4A69-B5D0-1E9C3A7F0002")!
    public static let defaultAccessibilityID = UUID(uuidString: "0D7E2C4B-8F31-4A69-B5D0-1E9C3A7F0003")!

    public init() {
        appearance = [AppearanceProfile(id: Self.defaultAppearanceID, name: "Default", settings: AppearanceSettings())]
        terminal = [TerminalProfile(id: Self.defaultTerminalID, name: "Default", settings: TerminalSettings())]
        accessibility = [AccessibilityProfile(id: Self.defaultAccessibilityID, name: "Default", settings: AccessibilitySettings())]
        keyboard = [.standard]
        toolbar = [.standard]
        sound = [.quiet]
        haptic = [.standard]
        bell = BellProfile.presets
        themes = TerminalTheme.builtIn
        defaults = HostProfileReferences(
            appearance: Self.defaultAppearanceID, terminal: Self.defaultTerminalID,
            keyboard: KeyboardProfile.standardID, toolbar: ToolbarProfile.standardID,
            accessibility: Self.defaultAccessibilityID, sound: SoundProfile.quietID,
            haptic: HapticProfile.standardID, bell: BellProfile.default.id
        )
    }

    /// Profiles in effect for a host: the host's own choice where it exists, the global
    /// default otherwise, and the built-in value if a referenced profile was deleted.
    public func resolved(for host: Host?) -> ResolvedProfiles {
        let refs = host?.profiles ?? HostProfileReferences()
        func pick<T: Identifiable>(_ list: [T], _ hostID: UUID?, _ defaultID: UUID?, fallback: T) -> T where T.ID == UUID {
            if let hostID, let match = list.first(where: { $0.id == hostID }) { return match }
            if let defaultID, let match = list.first(where: { $0.id == defaultID }) { return match }
            return list.first ?? fallback
        }
        var terminalSettings = pick(terminal, refs.terminal, defaults.terminal,
                                    fallback: TerminalProfile(name: "Default", settings: TerminalSettings())).settings
        if let override = host?.terminalType, !override.isEmpty {
            terminalSettings.terminalType = override
        }
        return ResolvedProfiles(
            appearance: pick(appearance, refs.appearance, defaults.appearance,
                             fallback: AppearanceProfile(name: "Default", settings: AppearanceSettings())).settings,
            terminal: terminalSettings,
            accessibility: pick(accessibility, refs.accessibility, defaults.accessibility,
                                fallback: AccessibilityProfile(name: "Default", settings: AccessibilitySettings())).settings,
            keyboard: pick(keyboard, refs.keyboard, defaults.keyboard, fallback: .standard),
            toolbar: pick(toolbar, refs.toolbar, defaults.toolbar, fallback: .standard),
            sound: pick(sound, refs.sound, defaults.sound, fallback: .quiet),
            haptic: pick(haptic, refs.haptic, defaults.haptic, fallback: .standard),
            bell: pick(bell, refs.bell, defaults.bell, fallback: .default)
        )
    }
}

/// The concrete settings a session runs with.
public struct ResolvedProfiles: Hashable, Sendable {
    public var appearance: AppearanceSettings
    public var terminal: TerminalSettings
    public var accessibility: AccessibilitySettings
    public var keyboard: KeyboardProfile
    public var toolbar: ToolbarProfile
    public var sound: SoundProfile
    public var haptic: HapticProfile
    public var bell: BellProfile
}

/// The non-secret export format for hosts and profiles. Never contains passwords,
/// private keys or Keychain references that would be meaningless on another device.
public struct ConnectionProfileExport: Codable, Sendable {
    public static let currentFormatVersion = 1

    public var formatVersion: Int
    public var exportedAt: Date
    public var hosts: [Host]
    public var groups: [HostGroup]
    public var profiles: ProfileLibrary

    public init(hosts: [Host], groups: [HostGroup], profiles: ProfileLibrary, exportedAt: Date = Date()) {
        formatVersion = Self.currentFormatVersion
        self.exportedAt = exportedAt
        // Strip secret references: they point at this device's Keychain only.
        self.hosts = hosts.map { host in
            var copy = host
            copy.authentication.savedPasswordID = nil
            copy.authentication.keyID = nil
            return copy
        }
        self.groups = groups
        self.profiles = profiles
    }
}
