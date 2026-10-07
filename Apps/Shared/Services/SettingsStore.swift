import Foundation
import Observation
import AcceSSHCore

/// All settings and profiles, saved as JSON. Global settings are the default profiles;
/// hosts may reference other profiles. Changes apply to open sessions immediately.
@MainActor @Observable
final class SettingsStore {
    var library: ProfileLibrary {
        didSet {
            file.save(library)
            onChange?()
        }
    }
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private let file = JSONFileStore<ProfileLibrary>(fileName: "settings.json")

    init() {
        library = file.load() ?? ProfileLibrary()
        ensureDefaultsExist()
    }

    /// Recreates any missing default profile (for example after a profile was deleted).
    private func ensureDefaultsExist() {
        var updated = library
        let fresh = ProfileLibrary()
        if updated.accessibility.first(where: { $0.id == updated.defaults.accessibility }) == nil {
            updated.accessibility.insert(fresh.accessibility[0], at: 0)
            updated.defaults.accessibility = fresh.accessibility[0].id
        }
        if updated.appearance.first(where: { $0.id == updated.defaults.appearance }) == nil {
            updated.appearance.insert(fresh.appearance[0], at: 0)
            updated.defaults.appearance = fresh.appearance[0].id
        }
        if updated.terminal.first(where: { $0.id == updated.defaults.terminal }) == nil {
            updated.terminal.insert(fresh.terminal[0], at: 0)
            updated.defaults.terminal = fresh.terminal[0].id
        }
        if updated.keyboard.first(where: { $0.id == updated.defaults.keyboard }) == nil {
            updated.keyboard.insert(.standard, at: 0)
            updated.defaults.keyboard = KeyboardProfile.standardID
        }
        if updated.toolbar.first(where: { $0.id == updated.defaults.toolbar }) == nil {
            updated.toolbar.insert(.standard, at: 0)
            updated.defaults.toolbar = ToolbarProfile.standardID
        }
        if updated.bell.isEmpty { updated.bell = BellProfile.presets }
        if updated.bell.first(where: { $0.id == updated.defaults.bell }) == nil {
            updated.defaults.bell = BellProfile.default.id
        }
        for theme in TerminalTheme.builtIn {
            // Built-in themes always reflect this version's palettes.
            if let index = updated.themes.firstIndex(where: { $0.id == theme.id }) {
                updated.themes[index] = theme
            } else {
                updated.themes.append(theme)
            }
        }
        if updated != library { library = updated }
    }

    // MARK: Global (default-profile) settings

    var accessibility: AccessibilitySettings {
        get { library.accessibility.first { $0.id == library.defaults.accessibility }?.settings ?? AccessibilitySettings() }
        set { update(\.accessibility, id: library.defaults.accessibility) { $0.settings = newValue } }
    }

    var appearance: AppearanceSettings {
        get { library.appearance.first { $0.id == library.defaults.appearance }?.settings ?? AppearanceSettings() }
        set { update(\.appearance, id: library.defaults.appearance) { $0.settings = newValue } }
    }

    var terminal: TerminalSettings {
        get { library.terminal.first { $0.id == library.defaults.terminal }?.settings ?? TerminalSettings() }
        set { update(\.terminal, id: library.defaults.terminal) { $0.settings = newValue } }
    }

    var keyboard: KeyboardProfile {
        get { library.keyboard.first { $0.id == library.defaults.keyboard } ?? .standard }
        set { update(\.keyboard, id: library.defaults.keyboard) { $0 = newValue } }
    }

    var toolbar: ToolbarProfile {
        get { library.toolbar.first { $0.id == library.defaults.toolbar } ?? .standard }
        set { update(\.toolbar, id: library.defaults.toolbar) { $0 = newValue } }
    }

    var defaultBellID: UUID {
        get { library.defaults.bell ?? BellProfile.default.id }
        set { library.defaults.bell = newValue }
    }

    func bellProfile(id: UUID) -> BellProfile? {
        library.bell.first { $0.id == id }
    }

    func updateBell(_ profile: BellProfile) {
        update(\.bell, id: profile.id) { $0 = profile }
    }

    func restoreBellPresets() {
        var bells = library.bell.filter { bell in !BellProfile.presets.contains { $0.id == bell.id } }
        bells.insert(contentsOf: BellProfile.presets, at: 0)
        library.bell = bells
    }

    private func update<Profile: Identifiable>(_ keyPath: WritableKeyPath<ProfileLibrary, [Profile]>, id: UUID?,
                                               _ change: (inout Profile) -> Void) where Profile.ID == UUID {
        guard let id, let index = library[keyPath: keyPath].firstIndex(where: { $0.id == id }) else { return }
        var updated = library
        change(&updated[keyPath: keyPath][index])
        library = updated
    }

    func resolved(for host: Host) -> ResolvedProfiles {
        library.resolved(for: host)
    }
}
