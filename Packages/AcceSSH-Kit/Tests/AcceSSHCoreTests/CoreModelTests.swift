import Foundation
import Testing
@testable import AcceSSHCore

@Suite("Core models")
struct CoreModelTests {
    @Test func productNamesFollowConventions() {
        #expect(AcceSSHProduct.displayName == "AcceSSH")
        #expect(AcceSSHProduct.internalName == "AcceSSH")
    }

    @Test func hostRoundTripsThroughJSON() throws {
        var host = Host(displayName: "Build box", hostname: "build.example.com", port: 2222, username: "matt")
        host.environment = [EnvironmentVariable(name: "LANG", value: "en_US.UTF-8")]
        host.portForwards = [PortForward(kind: .local, bindPort: 8080, destinationHost: "localhost", destinationPort: 80)]
        host.connection.reconnectPolicy = .standardAutomatic
        let data = try JSONEncoder().encode(host)
        #expect(try JSONDecoder().decode(Host.self, from: data) == host)
        #expect(host.connectionSummary == "matt@build.example.com:2222")
    }

    @Test func settingsSavedBeforeInputModesStillLoad() throws {
        // JSON written by a version without the input-mode fields.
        var keyboard = try JSONSerialization.jsonObject(with: JSONEncoder().encode(KeyboardProfile.standard)) as! [String: Any]
        keyboard.removeValue(forKey: "defaultInputMode")
        let decodedKeyboard = try JSONDecoder().decode(KeyboardProfile.self, from: JSONSerialization.data(withJSONObject: keyboard))
        #expect(decodedKeyboard.defaultInputMode == nil)

        var host = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Host(hostname: "h", username: "u"))) as! [String: Any]
        host.removeValue(forKey: "inputMode")
        #expect(try JSONDecoder().decode(Host.self, from: JSONSerialization.data(withJSONObject: host)).inputMode == nil)
    }

    @Test func threeFingerSwipesDefaultToArrowsAndAreConfigurable() throws {
        var profile = KeyboardProfile.standard
        #expect(profile.effectiveGestures.threeFingerSwipes[.left] == .key(KeyChord(.left)))
        profile.gestures = TerminalGestureSettings(threeFingerSwipes: [.up: .key(KeyChord(.pageUp)), .down: .app(.readNewOutput)])
        let decoded = try JSONDecoder().decode(KeyboardProfile.self, from: JSONEncoder().encode(profile))
        #expect(decoded.effectiveGestures.threeFingerSwipes[.up] == .key(KeyChord(.pageUp)))
        #expect(decoded.effectiveGestures.threeFingerSwipes[.down] == .app(.readNewOutput))
        #expect(decoded.effectiveGestures.threeFingerSwipes[.left] == nil)  // left: VoiceOver scrolls
    }

    @Test func hostValidation() {
        var host = Host(hostname: " ", port: 70_000, username: "u")
        host.environment = [EnvironmentVariable(name: "1BAD", value: "")]
        #expect(host.validationProblems.count == 3)
    }

    @Test func profileDictionariesEncodeAsKeyedObjects() throws {
        let data = try JSONEncoder().encode(SoundProfile.quiet)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"disconnected\""))
        #expect(try JSONDecoder().decode(SoundProfile.self, from: data) == SoundProfile.quiet)
    }

    @Test func hostKeyVerdicts() {
        let known = KnownHost(hostname: "Example.com", port: 22, keyType: "ssh-ed25519", publicKeyBase64: "AAAA1", fingerprintSHA256: "SHA256:x")
        #expect(HostKeyVerifier.verdict(hostname: "example.com", port: 22, keyType: "ssh-ed25519", publicKeyBase64: "AAAA1", knownHosts: [known]) == .trusted(known))
        #expect(HostKeyVerifier.verdict(hostname: "example.com", port: 22, keyType: "ssh-ed25519", publicKeyBase64: "BBBB", knownHosts: [known]) == .changed(previous: known))
        #expect(HostKeyVerifier.verdict(hostname: "example.com", port: 22, keyType: "ssh-rsa", publicKeyBase64: "CCCC", knownHosts: [known]) == .changed(previous: known))
        #expect(HostKeyVerifier.verdict(hostname: "example.com", port: 2222, keyType: "ssh-ed25519", publicKeyBase64: "AAAA1", knownHosts: [known]) == .unknown)
        #expect(known.knownHostsLine == "example.com ssh-ed25519 AAAA1")
    }

    @Test func reconnectBackoff() {
        let policy = ReconnectPolicy.automatic(maxAttempts: 4, initialDelay: 1, maxDelay: 5)
        #expect((1...5).map { policy.delay(beforeAttempt: $0) } == [1, 2, 4, 5, nil])
        #expect(ReconnectPolicy.ask.delay(beforeAttempt: 1) == nil)
    }

    @Test func historyPrivacyRules() {
        let settings = CommandHistorySettings()
        #expect(settings.allowsRecording("ls -la"))
        #expect(!settings.allowsRecording(" secret-command"))
        #expect(!settings.allowsRecording("export API_KEY=abc"))
        #expect(!settings.allowsRecording("mysql --password=hunter2"))
        #expect(!CommandHistorySettings(retention: .off).allowsRecording("ls"))
    }

    @Test func quietHoursWrapPastMidnight() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let quiet = QuietHours(startMinute: 22 * 60, endMinute: 7 * 60)
        func date(_ hour: Int) -> Date { calendar.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: hour))! }
        #expect(quiet.contains(date(23), calendar: calendar))
        #expect(quiet.contains(date(3), calendar: calendar))
        #expect(!quiet.contains(date(12), calendar: calendar))
    }

    @Test func builtInHighContrastThemesMeetWCAG() {
        for theme in [TerminalTheme.highContrastDark, .highContrastLight] {
            #expect(theme.foreground.contrastRatio(with: theme.background) >= 7)
            for (index, color) in theme.ansi.enumerated() where index != 0 && index != 8 && index != 7 && index != 15 {
                #expect(color.contrastRatio(with: theme.background) >= 4.5, "\(theme.name) color \(index)")
            }
        }
    }

    @Test func classicLightColorsAreReadable() {
        let theme = TerminalTheme.classicLight
        for index in [1, 2, 3, 4, 5, 6, 9, 10, 11, 12, 13, 14] {
            #expect(theme.ansi[index].contrastRatio(with: theme.background) >= 4.5, "color \(index)")
        }
    }

    @Test func xterm256Palette() {
        let theme = TerminalTheme.classicDark
        #expect(theme.color(forIndex: 16) == RGBColor(hex: 0x000000))
        #expect(theme.color(forIndex: 231) == RGBColor(hex: 0xFFFFFF))
        #expect(theme.color(forIndex: 232) == RGBColor(hex: 0x080808))
        #expect(theme.color(forIndex: 196) == RGBColor(hex: 0xFF0000))
    }

    @Test func profileResolutionFallsBack() {
        var library = ProfileLibrary()
        var host = Host(hostname: "h", username: "u")
        host.profiles.bell = BellProfile.strongAlertID
        host.profiles.sound = UUID()  // deleted profile
        host.terminalType = "vt220"
        let resolved = library.resolved(for: host)
        #expect(resolved.bell.id == BellProfile.strongAlertID)
        #expect(resolved.sound.id == SoundProfile.quietID)
        #expect(resolved.terminal.terminalType == "vt220")
        library.bell.removeAll()
        #expect(library.resolved(for: host).bell == .default)
    }

    @Test func exportStripsSecretReferences() {
        var host = Host(hostname: "h", username: "u")
        host.authentication.savedPasswordID = UUID()
        host.authentication.keyID = UUID()
        let export = ConnectionProfileExport(hosts: [host], groups: [], profiles: ProfileLibrary())
        #expect(export.hosts[0].authentication.savedPasswordID == nil)
        #expect(export.hosts[0].authentication.keyID == nil)
    }
}
