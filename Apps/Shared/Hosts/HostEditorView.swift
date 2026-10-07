import SwiftUI
import UniformTypeIdentifiers
import AcceSSHCore

struct HostEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var host: Host
    @State private var portText: String
    @State private var importingKey = false
    @State private var pastingKey = false
    @State private var generatingKey = false
    @State private var problems: [String] = []
    let onSave: (Host) -> Void

    init(host: Host, onSave: @escaping (Host) -> Void) {
        _host = State(initialValue: host)
        _portText = State(initialValue: String(host.port))
        self.onSave = onSave
    }

    private var isNew: Bool { host.hostname.isEmpty && host.displayName.isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                if !problems.isEmpty {
                    Section {
                        ForEach(problems, id: \.self) { Label($0, systemImage: "exclamationmark.triangle") }
                    }
                    .accessibilityElement(children: .combine)
                }
                Section("Server") {
                    TextField("Name", text: $host.displayName, prompt: Text("Optional, for example Home Server"))
                        .accessibilityLabel("Name")
                    TextField("Host Name or IP Address", text: $host.hostname)
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                    TextField("Port", text: $portText)
                        .keyboardType(.numberPad)
                    TextField("User Name", text: $host.username)
                        .textContentType(.username)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
                Section {
                    Picker("Private Key", selection: $host.authentication.keyID) {
                        Text("None").tag(UUID?.none)
                        ForEach(model.keys.keys) { key in
                            Text("\(key.name) (\(key.algorithm.spokenName))").tag(UUID?.some(key.id))
                        }
                    }
                    Button("Generate New Key…") { generatingKey = true }
                    Button("Import Key from Files…") { importingKey = true }
                    Button("Paste Private Key…") { pastingKey = true }
                    if let key = model.keys.key(id: host.authentication.keyID), !key.publicKey.isEmpty {
                        Button("Copy Public Key") {
                            Clipboard.copy(key.publicKey)
                        }
                        .accessibilityHint("Copies the public key so you can add it to the server’s authorized_keys file.")
                    }
                } header: {
                    Text("Authentication")
                } footer: {
                    Text("AcceSSH tries the key first, then asks for a password or answers server prompts if the server allows them. Keys and passwords are stored in the Keychain on this device only.")
                }
                Section {
                    ChoicePicker("Input Mode", selection: $host.inputMode,
                                 options: [ChoiceOption(InputModePreference?.none, "Same as Settings")]
                                    + InputModePreference.allCases.map { ChoiceOption(InputModePreference?.some($0), $0.displayName) })
                    ChoicePicker("Bell Style", selection: $host.profiles.bell,
                                 options: [ChoiceOption(UUID?.none, "Same as Settings")]
                                    + model.settings.library.bell.map { ChoiceOption(UUID?.some($0.id), $0.name) })
                    TextField("Terminal Type", text: Binding(
                        get: { host.terminalType ?? "" },
                        set: { host.terminalType = $0.isEmpty ? nil : $0 }
                    ), prompt: Text("Same as Settings"), axis: .vertical)
                    .accessibilityLabel("Terminal Type")
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                } header: {
                    SectionHeader("This Host")
                } footer: {
                    FooterText("Leave these as they are to use the choices in Settings.")
                }
                Section {
                    Toggle("Favorite", isOn: $host.isFavorite)
                    Picker("Shell Integration", selection: $host.shellIntegration) {
                        Text("Automatic").tag(ShellIntegrationPreference.automatic)
                        Text("Activate on Connect").tag(ShellIntegrationPreference.activateOnConnect)
                        Text("Off").tag(ShellIntegrationPreference.disabled)
                    }
                    TextField("Startup Command", text: Binding(
                        get: { host.startupCommand ?? "" },
                        set: { host.startupCommand = $0.isEmpty ? nil : $0 }
                    ))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                } header: {
                    Text("Options")
                }
            }
            .navigationTitle(isNew ? "New Host" : "Edit Host")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save) }
            }
            .fileImporter(isPresented: $importingKey, allowedContentTypes: [.data, .text, .item]) { result in
                importKey(from: result)
            }
            .sheet(isPresented: $generatingKey, onDismiss: {
                // Select the newest key if one was just generated.
                if let newest = model.keys.keys.last, host.authentication.keyID == nil { host.authentication.keyID = newest.id }
            }) {
                GenerateKeyView()
            }
            .sheet(isPresented: $pastingKey) {
                PasteKeyView { name, text in
                    try addKey(name: name, text: text)
                }
            }
        }
    }

    private func save() {
        host.port = Int(portText.trimmingCharacters(in: .whitespaces)) ?? 0
        host.hostname = host.hostname.trimmingCharacters(in: .whitespacesAndNewlines)
        host.username = host.username.trimmingCharacters(in: .whitespacesAndNewlines)
        problems = host.validationProblems
        if host.username.isEmpty { problems.append("Enter a user name.") }
        guard problems.isEmpty else {
            Announcer.announce(problems.joined(separator: " "))
            return
        }
        onSave(host)
        dismiss()
    }

    private func importKey(from result: Result<URL, any Error>) {
        do {
            let url = try result.get()
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let text = try String(contentsOf: url, encoding: .utf8)
            try addKey(name: url.deletingPathExtension().lastPathComponent, text: text)
        } catch {
            problems = [error.localizedDescription]
        }
    }

    private func addKey(name: String, text: String) throws {
        let key = try model.keys.importKey(name: name, privateKey: text)
        host.authentication.keyID = key.id
        problems = []
    }
}

/// Paste a private key's text, for keys copied from another app.
struct PasteKeyView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var text = ""
    @State private var error: String?
    let onAdd: (String, String) throws -> Void

    var body: some View {
        NavigationStack {
            Form {
                TextField("Key Name", text: $name, prompt: Text("For example Laptop Key"))
                    .accessibilityLabel("Key Name")
                Section("Private Key") {
                    TextEditor(text: $text)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(minHeight: 160)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .accessibilityLabel("Private key text")
                }
                if let error {
                    Text(error).foregroundStyle(.red)
                }
            }
            .navigationTitle("Paste Private Key")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        do {
                            try onAdd(name, text)
                            dismiss()
                        } catch {
                            self.error = error.localizedDescription
                        }
                    }
                    .disabled(text.isEmpty)
                }
            }
        }
    }
}
