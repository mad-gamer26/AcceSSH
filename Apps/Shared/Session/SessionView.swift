import SwiftUI
import AcceSSHCore
import AcceSSHTransport

/// A connected (or connecting) terminal session.
struct SessionView: View {
    @Environment(AppModel.self) private var model
    @Bindable var session: TerminalSession
    @State private var navigationRequest: TerminalNavigationRequest?
    @State private var showingDetails = false
    @State private var showingSettings = false
    @State private var showingShellIntegration = false

    var body: some View {
        VStack(spacing: 0) {
            statusBar
            TerminalScreen(session: session, mode: session.effectiveInputMode, isSecret: session.isSecretInputActive,
                           profiles: session.profiles, navigationRequest: $navigationRequest)
                .ignoresSafeArea(.keyboard)
        }
        .navigationTitle(session.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .onAppear {
            if case .idle = session.state { session.connect() }
        }
        .onChange(of: session.state) { _, state in
            if case .connected = state { navigationRequest = .focusInput }
        }
        .confirmationDialog(pasteTitle, isPresented: Binding(
            get: { session.pendingPaste != nil },
            set: { if !$0 { session.pendingPaste = nil } }
        ), titleVisibility: .visible) {
            Button("Paste") { if let text = session.pendingPaste { session.pasteNow(text) } }
            Button("Cancel", role: .cancel) { session.pendingPaste = nil }
        } message: {
            Text(pasteMessage)
        }
        .sheet(isPresented: $showingSettings) { SettingsView() }
        .sheet(isPresented: $showingShellIntegration) { ShellIntegrationView(session: session) }
        .confirmationDialog("Copy text from the server to the clipboard?", isPresented: Binding(
            get: { session.pendingClipboardWrite != nil },
            set: { if !$0 { session.pendingClipboardWrite = nil } }
        ), titleVisibility: .visible) {
            Button("Copy") {
                if let text = session.pendingClipboardWrite { Clipboard.copy(text) }
                session.pendingClipboardWrite = nil
            }
            Button("Don’t Copy", role: .cancel) { session.pendingClipboardWrite = nil }
        } message: {
            Text(String((session.pendingClipboardWrite ?? "").prefix(300)))
        }
        .sheet(item: $session.hostKeyPrompt) { prompt in
            HostKeyPromptView(prompt: prompt) { session.resolveHostKey(prompt, trust: $0) }
        }
        .sheet(item: $session.credentialPrompt) { prompt in
            CredentialPromptView(prompt: prompt) { session.resolveCredential(prompt, answer: $0) }
        }
        .sheet(item: $session.challengePrompt) { prompt in
            ChallengePromptView(prompt: prompt) { session.resolveChallenge(prompt, answers: $0) }
        }
    }

    /// Connection state, always first in focus order, with recovery actions on failure.
    @ViewBuilder private var statusBar: some View {
        let showsBar: Bool = switch session.state {
        case .connected: false
        default: true
        }
        if showsBar {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    if session.state.isActive { ProgressView().accessibilityHidden(true) }
                    Text(session.state.spokenDescription)
                        .font(.subheadline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let error = session.lastError, let detail = error.technicalDetail {
                    DisclosureGroup("Technical Details", isExpanded: $showingDetails) {
                        Text(detail).font(.footnote.monospaced()).textSelection(.enabled)
                    }
                    .font(.footnote)
                }
                if !session.state.isActive {
                    Button("Reconnect") { session.connect() }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding()
            .background(.bar)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Connection status")
        }
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Section("Read") {
                    command(.readNewOutput, "text.bubble")
                    command(.readCurrentLine, "text.alignleft")
                    command(.readLastCommand, "terminal")
                    command(.readLastCommandOutput, "text.page")
                    command(.describeScreen, "rectangle.and.text.magnifyingglass")
                    command(.speakCursorPosition, "cursorarrow")
                    command(.repeatLastAnnouncement, "arrow.counterclockwise")
                    Button(session.speech.isPaused ? "Resume Automatic Speech" : "Pause Automatic Speech",
                           systemImage: session.speech.isPaused ? "speaker.wave.2" : "speaker.slash") {
                        session.perform(.toggleAutomaticSpeech)
                    }
                }
                Section("Input") {
                    Picker("Input Mode", selection: Binding(
                        get: { session.preferredInputMode?.rawValue ?? "automatic" },
                        set: { session.setSessionInputMode(InputMode(rawValue: $0)) }
                    )) {
                        Text("Automatic").tag("automatic")
                        ForEach(InputMode.allCases) { Text($0.displayName).tag($0.rawValue) }
                    }
                    command(.paste, "doc.on.clipboard")
                    command(.copyLastCommandOutput, "doc.on.doc")
                }
                Section("Clear") {
                    command(.clearScreen, "eraser")
                    command(.clearScrollback, "clock.arrow.circlepath")
                    command(.clearScreenAndScrollback, "trash")
                }
                Section {
                    Button("Shell Integration…", systemImage: "terminal") { showingShellIntegration = true }
                    Button("Settings…", systemImage: "gear") { showingSettings = true }
                    if session.state.isActive {
                        Button("Disconnect", systemImage: "xmark.circle", role: .destructive) { session.disconnect() }
                    } else {
                        Button("Reconnect", systemImage: "arrow.clockwise") { session.connect() }
                    }
                }
            } label: {
                Label("Terminal Actions", systemImage: "ellipsis.circle")
            }
        }
    }

    private var pasteTitle: String {
        let lines = (session.pendingPaste ?? "").split(whereSeparator: \.isNewline).count
        return lines > 1 ? "Paste \(lines) lines?" : "Paste text?"
    }

    private var pasteMessage: String {
        let text = session.pendingPaste ?? ""
        let preview = text.count > 300 ? String(text.prefix(300)) + "…" : text
        return "Pasted lines may run as commands immediately.\n\n\(preview)"
    }

    private func command(_ command: AppCommand, _ symbol: String) -> some View {
        Button(command.displayName, systemImage: symbol) { session.perform(command) }
    }
}
