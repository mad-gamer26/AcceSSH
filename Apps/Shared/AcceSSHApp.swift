import SwiftUI
import AcceSSHCore

/// Shared app state: stores and open sessions.
@MainActor @Observable
final class AppModel {
    let hosts = HostStore()
    let keys = KeyStore()
    let knownHosts = KnownHostsStore()
    let settings = SettingsStore()
    let sounds = SoundLibrary()
    private(set) var sessions: [TerminalSession] = []

    init() {
        settings.onChange = { [weak self] in self?.applySettingsToSessions() }
        #if DEBUG
        seedForUITesting()
        seedSoundsForUITesting()
        #endif
    }

    #if DEBUG
    /// UI tests launch the app with ACCESSH_SEED_* variables to add a test host without
    /// going through the Files picker. Compiled into debug builds only.
    private func seedForUITesting() {
        let environment = ProcessInfo.processInfo.environment
        guard let hostname = environment["ACCESSH_SEED_HOST"], !hosts.hosts.contains(where: { $0.hostname == hostname }) else { return }
        var host = Host(displayName: "Test Server", hostname: hostname, username: environment["ACCESSH_SEED_USER"] ?? "")
        if let path = environment["ACCESSH_SEED_KEY_PATH"], let text = try? String(contentsOfFile: path, encoding: .utf8),
           let key = try? keys.importKey(name: "Test Key", privateKey: text) {
            host.authentication.keyID = key.id
        }
        hosts.save(host)
    }

    /// UI tests pass ACCESSH_SEED_SOUNDS (paths separated by "|") to exercise sound import.
    private func seedSoundsForUITesting() {
        guard let paths = ProcessInfo.processInfo.environment["ACCESSH_SEED_SOUNDS"] else { return }
        // Start from an empty library so repeated test runs see the same screen.
        for name in sounds.sounds { sounds.delete(name) }
        for path in paths.split(separator: "|") {
            do {
                try sounds.importSound(from: URL(fileURLWithPath: String(path)))
            } catch {
                seedErrors.append(error.localizedDescription)
            }
        }
    }

    /// Import errors from seeding, shown on the host list so UI tests can check them.
    var seedErrors: [String] = []
    #endif

    /// Opens (or returns the existing) session for a host.
    func session(for host: Host) -> TerminalSession {
        if let existing = sessions.first(where: { $0.host.id == host.id && $0.state.isActive }) {
            return existing
        }
        let session = TerminalSession(host: host, knownHosts: knownHosts, keys: keys, hostStore: hosts,
                                      profiles: settings.resolved(for: host), themes: settings.library.themes)
        sessions.append(session)
        return session
    }

    private func applySettingsToSessions() {
        for session in sessions {
            let host = hosts.hosts.first { $0.id == session.host.id } ?? session.host
            session.apply(settings.resolved(for: host), themes: settings.library.themes)
        }
    }

    func close(_ session: TerminalSession) {
        session.disconnect()
        sessions.removeAll { $0.id == session.id }
    }
}

@main
struct AcceSSHApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            HostListView()
                .environment(model)
                .tint(.accessibleAccent)
        }
    }
}

extension Color {
    /// Red for destructive actions with at least 4.5:1 contrast in light and dark mode
    /// (the system red falls short on white).
    static let accessibleDestructive = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 1.0, green: 0.55, blue: 0.53, alpha: 1)
            : UIColor(red: 0.72, green: 0.0, blue: 0.08, alpha: 1)
    })

    /// Accent color with at least 4.5:1 contrast against system backgrounds in light and
    /// dark mode (the default blue is slightly below that on white).
    static let accessibleAccent: Color = {
        Color(UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.42, green: 0.71, blue: 1.0, alpha: 1)
                : UIColor(red: 0.0, green: 0.31, blue: 0.80, alpha: 1)
        })
    }()
}
