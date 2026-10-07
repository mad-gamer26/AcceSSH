import Foundation
import Observation
import AcceSSHCore
import AcceSSHTerminal
import AcceSSHAccessibility
import AcceSSHShellIntegration
import AcceSSHTransport

/// A host-key decision the person must make before the connection continues.
struct HostKeyPrompt: Identifiable {
    enum Kind {
        case firstConnection
        case changed(previous: KnownHost)
    }

    let id = UUID()
    let hostname: String
    let port: Int
    let key: SSHHostKey
    let kind: Kind
    fileprivate let continuation: CheckedContinuation<Bool, Never>
}

/// A request for a password or key passphrase.
struct CredentialPrompt: Identifiable {
    enum Purpose { case password, keyPassphrase(keyName: String) }

    let id = UUID()
    let purpose: Purpose
    let message: String
    fileprivate let continuation: CheckedContinuation<(secret: String, save: Bool)?, Never>
}

/// A keyboard-interactive round awaiting answers.
struct ChallengePrompt: Identifiable {
    let id = UUID()
    let challenge: SSHKeyboardInteractiveChallenge
    fileprivate let continuation: CheckedContinuation<[String]?, Never>
}

/// How typed text reaches the server.
enum InputMode: String, CaseIterable, Identifiable {
    /// A native text field: compose a whole command with full VoiceOver editing, then send it.
    case line
    /// Every key goes straight to the server (needed for vim, less, menus and tab completion).
    case keys

    var id: String { rawValue }
    var displayName: String { self == .line ? "Line Editing" : "Direct Keys" }
}

/// One terminal session: SSH connection, emulator, speech and input.
@MainActor @Observable
final class TerminalSession: Identifiable {
    let id = UUID()
    let host: Host
    private(set) var state: SessionConnectionState = .idle
    private(set) var title: String
    private(set) var lastError: SSHError?
    var hostKeyPrompt: HostKeyPrompt?
    var credentialPrompt: CredentialPrompt?
    var challengePrompt: ChallengePrompt?
    /// The input mode in effect; `nil` means automatic (line editing at the shell, direct keys
    /// in full-screen programs). Starts from the host's or keyboard settings' default.
    private(set) var preferredInputMode: InputMode? {
        didSet { syncSpeechMode() }
    }
    /// True once the person picks a mode from the session menu; settings changes then leave it alone.
    @ObservationIgnored private var hasSessionInputOverride = false
    private(set) var isAlternateScreen = false
    /// The cursor line looks like a password prompt: line input switches to a secure field.
    private(set) var isSecretInputActive = false
    private(set) var shellIntegration = ShellIntegrationState()
    /// Commands typed in line mode, newest last (session-only history).
    private(set) var history: [String] = []

    @ObservationIgnored let terminal: TerminalEmulator
    @ObservationIgnored let speech: SpeechCoordinator
    @ObservationIgnored private(set) var encoder = TerminalInputEncoder()
    /// The settings in effect for this session (global defaults plus the host's profiles).
    private(set) var profiles: ResolvedProfiles
    private(set) var themes: [TerminalTheme] = TerminalTheme.builtIn
    /// Multiline or large text waiting for paste confirmation.
    var pendingPaste: String?
    /// Text a program on the server asked to put on the clipboard (OSC 52), awaiting approval.
    var pendingClipboardWrite: String?
    /// Called after every emulator update; the terminal view redraws from it.
    @ObservationIgnored var onTerminalUpdate: ((TerminalUpdate) -> Void)?
    @ObservationIgnored private var connection: SSHConnection?
    @ObservationIgnored private var channel: SSHChannel?
    @ObservationIgnored private var outbound: AsyncStream<[UInt8]>.Continuation?
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private let integrationToken = UUID().uuidString
    @ObservationIgnored private let knownHosts: KnownHostsStore
    @ObservationIgnored private let keys: KeyStore
    @ObservationIgnored private let hostStore: HostStore
    @ObservationIgnored private var pendingResize: (columns: Int, rows: Int)?
    @ObservationIgnored private var historySettings = CommandHistorySettings()

    init(host: Host, knownHosts: KnownHostsStore, keys: KeyStore, hostStore: HostStore, profiles: ResolvedProfiles, themes: [TerminalTheme]) {
        self.host = host
        self.profiles = profiles
        self.themes = themes
        self.knownHosts = knownHosts
        self.keys = keys
        self.hostStore = hostStore
        title = host.effectiveDisplayName
        terminal = TerminalEmulator(columns: 80, rows: 24, scrollbackLimit: profiles.terminal.scrollbackLines)
        terminal.expectedIntegrationToken = integrationToken
        terminal.isShellIntegrationDisabled = host.shellIntegration == .disabled
        speech = SpeechCoordinator(settings: profiles.accessibility.voiceOver, terminal: terminal)
        encoder = TerminalInputEncoder(optionSendsEscape: profiles.keyboard.optionSendsEscape,
                                       backspaceSendsDelete: profiles.terminal.backspaceSendsDelete)
        historySettings = profiles.terminal.history
        preferredInputMode = Self.inputMode(host.inputMode ?? profiles.keyboard.defaultInputMode)
        speech.onSecretPromptChange = { [weak self] secret in
            guard let self, self.isSecretInputActive != secret else { return }
            self.isSecretInputActive = secret
            self.syncSpeechMode()
        }
    }

    /// Applies changed settings to the running session.
    func apply(_ newProfiles: ResolvedProfiles, themes newThemes: [TerminalTheme]) {
        profiles = newProfiles
        themes = newThemes
        speech.settings = newProfiles.accessibility.voiceOver
        encoder = TerminalInputEncoder(optionSendsEscape: newProfiles.keyboard.optionSendsEscape,
                                       backspaceSendsDelete: newProfiles.terminal.backspaceSendsDelete)
        terminal.scrollbackLimit = newProfiles.terminal.scrollbackLines
        historySettings = newProfiles.terminal.history
        if historySettings.retention == .off { history.removeAll() }
        if !hasSessionInputOverride {
            preferredInputMode = Self.inputMode(host.inputMode ?? newProfiles.keyboard.defaultInputMode)
        }
    }

    /// Chooses the input mode for this session only (from the Terminal Actions menu).
    func setSessionInputMode(_ mode: InputMode?) {
        hasSessionInputOverride = true
        preferredInputMode = mode
    }

    private static func inputMode(_ preference: InputModePreference?) -> InputMode? {
        switch preference {
        case .lineEditing: .line
        case .directKeys: .keys
        case .automatic, nil: nil
        }
    }

    /// In direct-keys mode the screen is the only record of what was typed, so everything is spoken.
    private func syncSpeechMode() {
        speech.speaksAllTypedText = effectiveInputMode == .keys
    }

    var effectiveInputMode: InputMode {
        if isSecretInputActive { return .line }
        return preferredInputMode ?? (isAlternateScreen ? .keys : .line)
    }

    // MARK: - Connecting

    func connect() {
        guard !state.isActive else { return }
        runTask?.cancel()
        runTask = Task { await run() }
    }

    func disconnect() {
        runTask?.cancel()
        connection?.disconnect()
        outbound?.finish()
        connection = nil
        channel = nil
        setState(.disconnected(reason: nil))
    }

    private func setState(_ newState: SessionConnectionState) {
        guard state != newState else { return }
        state = newState
        if let utterance = AnnouncementComposer.connectionState(newState, hostName: host.effectiveDisplayName),
           speech.settings.isEnabled(.connection) {
            speech.say(utterance)
        }
    }

    private func run() async {
        lastError = nil
        setState(.connecting)
        let connection = SSHConnection(host: host)
        self.connection = connection
        do {
            let key = try await connection.connect()
            setState(.verifyingHostKey)
            guard await verify(key) else {
                connection.disconnect()
                setState(.disconnected(reason: "The host key was not trusted."))
                return
            }
            setState(.authenticating)
            try await authenticate(connection)
            var environment: [(name: String, value: String)] = [
                ("LC_TERMINAL", AcceSSHProduct.terminalEnvironmentValue),
                ("LC_TERMINAL_VERSION", "1.0"),
                (AcceSSHProduct.integrationTokenEnvironmentKey, integrationToken),
            ]
            environment += host.environment.map { ($0.name, $0.value) }
            // The login shell decides which integration script applies. Failure here is harmless.
            if let shellPath = try? await connection.execute("printf '%s' \"$SHELL\"").outputText {
                loginShell = ShellKind(shellPath: shellPath)
            }
            let channel = try await connection.openShell(SSHShellRequest(
                terminalType: profiles.terminal.terminalType,
                columns: terminal.columns, rows: terminal.rows, environment: environment
            ))
            self.channel = channel
            startSending(on: channel)
            hostStore.markConnected(host.id)
            setState(.connected)
            if let pendingResize { resize(columns: pendingResize.columns, rows: pendingResize.rows) }
            if let startup = host.startupCommand, !startup.isEmpty { send(text: startup + "\r") }
            if host.shellIntegration == .activateOnConnect { activateIntegrationWhenReady() }

            for await data in channel.output {
                receive(data)
            }
            let status = await channel.exitStatus()
            if !Task.isCancelled {
                setState(.disconnected(reason: status.map { $0 == 0 ? "The shell exited." : "The shell exited with status \($0)." }))
            }
            connection.disconnect()
        } catch let error as SSHError {
            fail(error)
        } catch {
            fail(.protocolError(code: 0, detail: error.localizedDescription))
        }
    }

    private func fail(_ error: SSHError) {
        connection?.disconnect()
        guard !Task.isCancelled, error != .cancelled else {
            setState(.disconnected(reason: nil))
            return
        }
        lastError = error
        setState(.failed(message: error.userMessage))
    }

    private func verify(_ key: SSHHostKey) async -> Bool {
        switch knownHosts.verdict(hostname: host.hostname, port: host.port, key: key) {
        case let .trusted(entry):
            knownHosts.touch(entry)
            return true
        case .unknown:
            let trusted = await withCheckedContinuation { continuation in
                hostKeyPrompt = HostKeyPrompt(hostname: host.hostname, port: host.port, key: key,
                                              kind: .firstConnection, continuation: continuation)
            }
            if trusted { knownHosts.trust(hostname: host.hostname, port: host.port, key: key) }
            return trusted
        case let .changed(previous):
            if speech.settings.isEnabled(.hostKey) {
                speech.say("Warning. The host key for \(host.effectiveDisplayName) has changed.", priority: .high)
            }
            let replace = await withCheckedContinuation { continuation in
                hostKeyPrompt = HostKeyPrompt(hostname: host.hostname, port: host.port, key: key,
                                              kind: .changed(previous: previous), continuation: continuation)
            }
            if replace { knownHosts.trust(hostname: host.hostname, port: host.port, key: key) }
            return replace
        }
    }

    func resolveHostKey(_ prompt: HostKeyPrompt, trust: Bool) {
        hostKeyPrompt = nil
        prompt.continuation.resume(returning: trust)
    }

    private func authenticate(_ connection: SSHConnection) async throws {
        let username = host.username
        let serverMethods = try await connection.authenticationMethods(username: username)
        if serverMethods.isEmpty { return }
        var lastFailure: SSHError?

        for method in host.authentication.methods {
            switch method {
            case .publicKey:
                guard serverMethods.contains("publickey"), let key = keys.key(id: host.authentication.keyID),
                      let privateKey = await keys.privateKey(for: key) else { continue }
                var passphrase: String?
                if key.hasPassphrase {
                    let keyID = key.id
                    passphrase = await Task.detached { Keychain.get(kind: .passphrase, id: keyID) }.value
                    if passphrase == nil {
                        guard let answer = await askCredential(.keyPassphrase(keyName: key.name),
                                                               message: "Enter the passphrase for the key “\(key.name)”.") else {
                            throw SSHError.cancelled
                        }
                        passphrase = answer.secret
                        if answer.save { _ = Keychain.set(answer.secret, kind: .passphrase, id: key.id) }
                    }
                }
                do {
                    try await connection.authenticate(username: username, privateKey: privateKey, passphrase: passphrase)
                    return
                } catch let error as SSHError {
                    lastFailure = error
                }
            case .password:
                guard serverMethods.contains("password") else { continue }
                var password: String?
                if let passwordID = host.authentication.savedPasswordID {
                    password = await Task.detached { Keychain.get(kind: .password, id: passwordID) }.value
                }
                var save = false
                if password == nil {
                    guard let answer = await askCredential(.password, message: "Enter the password for \(host.connectionSummary).") else {
                        throw SSHError.cancelled
                    }
                    password = answer.secret
                    save = answer.save
                }
                do {
                    try await connection.authenticate(username: username, password: password ?? "")
                    if save, let password { savePassword(password) }
                    return
                } catch let error as SSHError {
                    lastFailure = error
                }
            case .keyboardInteractive:
                guard serverMethods.contains("keyboard-interactive") else { continue }
                do {
                    try await connection.authenticateKeyboardInteractive(username: username) { [weak self] challenge in
                        await self?.askChallenge(challenge)
                    }
                    return
                } catch let error as SSHError {
                    if error == .cancelled { throw error }
                    lastFailure = error
                }
            case .agent:
                continue
            }
        }
        if let lastFailure { throw lastFailure }
        throw SSHError.noAcceptedAuthenticationMethod(serverMethods: serverMethods)
    }

    private func savePassword(_ password: String) {
        var updated = host
        let id = updated.authentication.savedPasswordID ?? UUID()
        if Keychain.set(password, kind: .password, id: id) {
            updated.authentication.savedPasswordID = id
            hostStore.save(updated)
        }
    }

    private func askCredential(_ purpose: CredentialPrompt.Purpose, message: String) async -> (secret: String, save: Bool)? {
        await withCheckedContinuation { continuation in
            credentialPrompt = CredentialPrompt(purpose: purpose, message: message, continuation: continuation)
        }
    }

    func resolveCredential(_ prompt: CredentialPrompt, answer: (secret: String, save: Bool)?) {
        credentialPrompt = nil
        prompt.continuation.resume(returning: answer)
    }

    private func askChallenge(_ challenge: SSHKeyboardInteractiveChallenge) async -> [String]? {
        await withCheckedContinuation { continuation in
            challengePrompt = ChallengePrompt(challenge: challenge, continuation: continuation)
        }
    }

    func resolveChallenge(_ prompt: ChallengePrompt, answers: [String]?) {
        challengePrompt = nil
        prompt.continuation.resume(returning: answers)
    }

    // MARK: - Terminal I/O

    private func receive(_ data: Data) {
        let update = terminal.feed(data)
        if !update.responses.isEmpty { send(bytes: update.responses) }
        for event in update.events { handle(event) }
        if isAlternateScreen != terminal.isAlternateScreenActive { isAlternateScreen = terminal.isAlternateScreenActive }
        syncSpeechMode()
        onTerminalUpdate?(update)
        speech.ingest(update)
    }

    private func handle(_ event: TerminalEvent) {
        switch event {
        case let .titleChanged(newTitle):
            guard profiles.terminal.allowTitleChanges else { break }
            title = newTitle.isEmpty ? host.effectiveDisplayName : newTitle
        case .bell:
            BellPlayer.ring(profile: profiles.bell, speech: speech)
        case let .commandFinished(command):
            if let utterance = AnnouncementComposer.commandFinished(command, settings: speech.settings) {
                speech.say(utterance)
            }
        case let .shellIntegrationChanged(state):
            shellIntegration = state
            if speech.settings.isEnabled(.shellIntegration),
               let utterance = AnnouncementComposer.shellIntegrationChanged(state) {
                speech.say(utterance)
            }
        case let .clipboardWriteRequested(text):
            switch profiles.terminal.remoteClipboardWrite {
            case .allow:
                Clipboard.copy(text)
                speech.say("The server copied text to the clipboard.", priority: .low)
            case .ask:
                pendingClipboardWrite = text
            case .deny:
                break
            }
        case let .remoteNotification(title, body, _):
            if profiles.terminal.allowRemoteNotifications, speech.settings.isEnabled(.remoteNotifications) {
                speech.say([title, body].compactMap { $0 }.joined(separator: ": "))
            }
        default:
            break
        }
    }

    private func startSending(on channel: SSHChannel) {
        let (stream, continuation) = AsyncStream.makeStream(of: [UInt8].self)
        outbound = continuation
        // A single consumer keeps keystrokes in order.
        Task {
            for await bytes in stream {
                try? await channel.write(bytes)
            }
        }
    }

    func send(bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        outbound?.yield(bytes)
    }

    func send(text: String) {
        speech.noteTyped(text)
        send(bytes: Array(text.utf8))
    }

    func send(_ chord: KeyChord) {
        let bytes = encoder.encode(chord, modes: terminal.modes)
        if chord.key == .enter {
            speech.noteSubmitted()
            if !terminal.shellIntegrationState.isAuthoritative, !terminal.isAlternateScreenActive {
                terminal.noteHeuristicCommandSubmitted(commandLine: nil)
            }
        } else if case let .text(text) = chord.key {
            speech.noteTyped(text)
        }
        send(bytes: bytes)
    }

    /// Sends a composed line from line-editing mode, followed by Return.
    func submitLine(_ line: String) {
        let isSecret = isSecretInputActive
        if !isSecret, historySettings.allowsRecording(line) {
            history.removeAll { $0 == line }
            history.append(line)
        }
        if !isSecret, !terminal.shellIntegrationState.isAuthoritative {
            terminal.noteHeuristicCommandSubmitted(commandLine: line)
        }
        speech.noteSubmitted()
        send(bytes: Array(line.utf8) + [0x0D])
        if isSecret {
            isSecretInputActive = false
            syncSpeechMode()
        }
    }

    /// Pastes text, asking first when the paste-confirmation setting calls for it.
    func paste(_ text: String) {
        let settings = profiles.terminal
        let isMultiline = text.contains("\n") || text.contains("\r")
        let needsConfirmation = switch settings.pasteConfirmation {
        case .always: true
        case .whenMultiline: isMultiline || text.count > settings.largePasteThreshold
        case .never: text.count > settings.largePasteThreshold
        }
        if needsConfirmation {
            pendingPaste = text
        } else {
            pasteNow(text)
        }
    }

    /// Sends pasted text, using bracketed paste when the remote program asked for it.
    func pasteNow(_ text: String) {
        pendingPaste = nil
        let bracketed = terminal.modes.bracketedPaste && profiles.terminal.allowBracketedPaste
        send(bytes: encoder.encodePaste(text, bracketed: bracketed))
    }

    func resize(columns: Int, rows: Int) {
        guard columns != terminal.columns || rows != terminal.rows || pendingResize != nil else { return }
        terminal.resize(columns: columns, rows: rows)
        onTerminalUpdate?(terminal.takePendingUpdate())
        guard let channel else {
            pendingResize = (columns, rows)
            return
        }
        pendingResize = nil
        Task { try? await channel.resize(columns: columns, rows: rows) }
    }

    // MARK: - Shell integration

    /// The server's login shell, detected when connecting.
    private(set) var loginShell: ShellKind?

    /// A manager for installing or removing integration over this session's connection.
    func integrationManager() -> RemoteShellIntegrationManager? {
        guard let connection, state == .connected else { return nil }
        return RemoteShellIntegrationManager(connection: connection)
    }

    /// Loads the installed integration script into the running shell (without touching any
    /// startup file). The command starts with a space so shells that hide such commands keep
    /// it out of history.
    func activateIntegrationNow() {
        guard let shell = loginShell, channel != nil else { return }
        speech.noteSubmitted()
        send(bytes: Array((ShellIntegrationScripts.activationCommand(for: shell) + "\r").utf8))
    }

    /// "Activate on Connect": waits for the first prompt, then activates if nothing else did.
    private func activateIntegrationWhenReady() {
        Task { [weak self] in
            for _ in 0..<40 {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, self.state == .connected else { return }
                if self.terminal.shellIntegrationState.isAuthoritative { return }
                let line = self.terminal.logicalLineText(atAbsoluteRow: self.terminal.cursorPosition.row)
                if HeuristicPromptDetector().isLikelyPrompt(line) {
                    self.activateIntegrationNow()
                    return
                }
            }
        }
    }

    // MARK: - Accessibility commands

    func perform(_ command: AppCommand) {
        switch command {
        case .readNewOutput:
            speech.say(speech.takeUnreadOutput() ?? "No new output.")
        case .readCurrentLine:
            let line = terminal.isAlternateScreenActive
                ? terminal.screenLine(terminal.cursorScreenPosition.row).text
                : terminal.logicalLineText(atAbsoluteRow: terminal.cursorPosition.row)
            speech.say(line.isEmpty ? "Blank" : line)
        case .readFromCursor:
            let text = terminal.textFromCursor()
            speech.say(text.isEmpty ? "Blank" : text)
        case .readLastCommand:
            speech.say(SemanticNavigator.lastCommandDescription(in: terminal))
        case .readLastCommandOutput:
            speech.say(SemanticNavigator.lastCommandOutput(in: terminal))
        case .copyLastCommandOutput:
            if let command = terminal.lastExecutedCommand, let output = terminal.outputText(of: command) {
                Clipboard.copy(output)
                speech.say("Copied last command output.")
            } else {
                speech.say("No command output to copy.")
            }
        case .repeatLastAnnouncement:
            speech.repeatLastAnnouncement()
        case .toggleAutomaticSpeech:
            speech.say(speech.togglePause() ? "Automatic speech paused." : "Automatic speech resumed.")
        case .speakCursorPosition:
            let position = terminal.cursorScreenPosition
            speech.say(AnnouncementComposer.cursorPosition(row: position.row, column: position.column))
        case .describeScreen:
            speech.say(ScreenDescriber.describe(terminal))
        case .clearScreen:
            terminal.clearScreen()
            onTerminalUpdate?(terminal.takePendingUpdate())
            speech.say("Screen cleared. Scrollback kept.")
        case .clearScrollback:
            terminal.clearScrollback()
            onTerminalUpdate?(terminal.takePendingUpdate())
            speech.say("Scrollback cleared. Screen kept.")
        case .clearScreenAndScrollback:
            terminal.clearScreenAndScrollback()
            onTerminalUpdate?(terminal.takePendingUpdate())
            speech.say("Screen and scrollback cleared.")
        case .reconnect:
            disconnect()
            connect()
        case .disconnect:
            disconnect()
        case .paste:
            if let text = Clipboard.text { paste(text) }
        default:
            // Navigation commands move VoiceOver focus and are handled by the terminal view.
            break
        }
    }
}
