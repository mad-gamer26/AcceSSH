import SwiftUI
import AcceSSHCore
import AcceSSHTransport

/// First-connection confirmation or changed-key warning. A changed key is never accepted
/// by default: the safe choice is the default button, and replacing requires a second step.
struct HostKeyPromptView: View {
    let prompt: HostKeyPrompt
    let resolve: (Bool) -> Void
    @State private var confirmingReplace = false

    var body: some View {
        NavigationStack {
            Form {
                switch prompt.kind {
                case .firstConnection:
                    Section {
                        Text("This is the first time you’re connecting to \(prompt.hostname). Check that the fingerprint below matches the server’s before you trust it.")
                    }
                case let .changed(previous):
                    Section {
                        Label {
                            Text("The host key for \(prompt.hostname) has changed. This can happen if the server was reinstalled, but it can also mean someone is intercepting your connection. Don’t continue unless you know why the key changed.")
                        } icon: {
                            Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(.red)
                        }
                    }
                    Section("Previously Trusted Key") {
                        InfoRow("Type", value: previous.keyType)
                        FingerprintRow(fingerprint: previous.fingerprintSHA256)
                    }
                }
                Section(isChanged ? "New Key" : "Server Key") {
                    InfoRow("Type", value: prompt.key.keyType)
                    FingerprintRow(fingerprint: prompt.key.fingerprintSHA256)
                }
                Section {
                    if isChanged {
                        Button("Disconnect") { resolve(false) }
                            .bold()
                        Button("Replace Stored Key and Connect…", role: .destructive) { confirmingReplace = true }
                            .foregroundStyle(Color.accessibleDestructive)
                    } else {
                        Button("Trust and Connect") { resolve(true) }
                            .bold()
                        Button("Cancel", role: .cancel) { resolve(false) }
                    }
                }
            }
            .navigationTitle(isChanged ? "Host Key Changed" : "Verify Host Key")
            .confirmationDialog("Replace the stored host key for \(prompt.hostname)?", isPresented: $confirmingReplace,
                                titleVisibility: .visible) {
                Button("Replace and Connect", role: .destructive) { resolve(true) }
                Button("Disconnect", role: .cancel) { resolve(false) }
            }
        }
        .interactiveDismissDisabled()
    }

    private var isChanged: Bool {
        if case .changed = prompt.kind { true } else { false }
    }
}

private struct FingerprintRow: View {
    let fingerprint: String

    var body: some View {
        VStack(alignment: .leading) {
            Text("SHA-256 Fingerprint").font(.caption).foregroundStyle(.secondary)
            Text(fingerprint.replacingOccurrences(of: "SHA256:", with: ""))
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("SHA-256 fingerprint")
        // Grouped in fours so VoiceOver reads it clearly; use the rotor's Characters setting
        // to check it character by character.
        .accessibilityValue(SSHHostKey(keyType: "", publicKeyBase64: "", fingerprintSHA256: fingerprint).spokenFingerprint)
    }
}

/// Password or passphrase entry in a secure field.
struct CredentialPromptView: View {
    let prompt: CredentialPrompt
    let resolve: ((secret: String, save: Bool)?) -> Void
    @State private var secret = ""
    @State private var save = false
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(prompt.message)
                    SecureField(fieldLabel, text: $secret)
                        .focused($focused)
                        .onSubmit(submit)
                    Toggle(saveLabel, isOn: $save)
                }
            }
            .navigationTitle(fieldLabel)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { resolve(nil) } }
                ToolbarItem(placement: .confirmationAction) { Button("Sign In", action: submit).disabled(secret.isEmpty) }
            }
            .onAppear { focused = true }
        }
        .interactiveDismissDisabled()
    }

    private var fieldLabel: String {
        switch prompt.purpose {
        case .password: "Password"
        case .keyPassphrase: "Key Passphrase"
        }
    }

    private var saveLabel: String {
        switch prompt.purpose {
        case .password: "Save Password in Keychain"
        case .keyPassphrase: "Save Passphrase in Keychain"
        }
    }

    private func submit() {
        guard !secret.isEmpty else { return }
        resolve((secret, save))
    }
}

/// Keyboard-interactive prompts (one-time codes, PAM). Prompts that don't echo use secure fields.
struct ChallengePromptView: View {
    let prompt: ChallengePrompt
    let resolve: ([String]?) -> Void
    @State private var answers: [String]
    @FocusState private var focusedIndex: Int?

    init(prompt: ChallengePrompt, resolve: @escaping ([String]?) -> Void) {
        self.prompt = prompt
        self.resolve = resolve
        _answers = State(initialValue: Array(repeating: "", count: prompt.challenge.prompts.count))
    }

    var body: some View {
        NavigationStack {
            Form {
                if !prompt.challenge.instruction.isEmpty {
                    Section { Text(prompt.challenge.instruction) }
                }
                Section {
                    ForEach(Array(prompt.challenge.prompts.enumerated()), id: \.offset) { index, item in
                        let label = item.text.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: ":"))
                        Group {
                            if item.echo {
                                TextField(label, text: $answers[index])
                                    .autocorrectionDisabled()
                                    .textInputAutocapitalization(.never)
                            } else {
                                SecureField(label, text: $answers[index])
                            }
                        }
                        .focused($focusedIndex, equals: index)
                        .onSubmit { focusedIndex = index + 1 < answers.count ? index + 1 : nil }
                    }
                }
            }
            .navigationTitle(prompt.challenge.name.isEmpty ? "Sign In" : prompt.challenge.name)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { resolve(nil) } }
                ToolbarItem(placement: .confirmationAction) { Button("Continue") { resolve(answers) } }
            }
            .onAppear { focusedIndex = 0 }
        }
        .interactiveDismissDisabled()
    }
}
