import SwiftUI
import UniformTypeIdentifiers
import AcceSSHCore
import AcceSSHTransport

/// Lists, generates, imports and deletes SSH keys.
struct KeysSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var generating = false
    @State private var pasting = false
    @State private var importing = false
    @State private var deleting: SSHKey?
    @State private var error: String?

    var body: some View {
        List {
            Section {
                if model.keys.keys.isEmpty {
                    Text("No keys yet. Generate a key on this device, then add its public key to your server.")
                }
                ForEach(model.keys.keys) { key in
                    NavigationLink {
                        KeyDetailView(key: key)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(key.name).font(.headline)
                            Text(key.algorithm.spokenName + (key.requireUserPresence ? ", requires Face ID or passcode" : ""))
                                .font(.subheadline)
                        }
                        .accessibilityElement(children: .combine)
                    }
                    .swipeActions {
                        Button("Delete", role: .destructive) { deleting = key }
                    }
                    .accessibilityAction(named: "Delete") { deleting = key }
                }
            }
            Section {
                Button("Generate New Key…") { generating = true }
                Button("Import Key from Files…") { importing = true }
                Button("Paste Private Key…") { pasting = true }
            }
            if let error {
                Section { Text(error).foregroundStyle(.red) }
            }
        }
        .sheet(isPresented: $generating) { GenerateKeyView() }
        .sheet(isPresented: $pasting) {
            PasteKeyView { name, text in _ = try model.keys.importKey(name: name, privateKey: text) }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data, .text, .item]) { result in
            do {
                let url = try result.get()
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                _ = try model.keys.importKey(name: url.deletingPathExtension().lastPathComponent,
                                             privateKey: String(contentsOf: url, encoding: .utf8))
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
        }
        .confirmationDialog("Delete the key “\(deleting?.name ?? "")”?", isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }
        ), titleVisibility: .visible) {
            Button("Delete Key", role: .destructive) {
                if let deleting { model.keys.delete(deleting) }
                deleting = nil
            }
        } message: {
            Text("Hosts using this key will need another way to sign in. This can’t be undone.")
        }
    }
}

/// Public key details with copy and share, so it can be added to a server.
struct KeyDetailView: View {
    let key: SSHKey
    @State private var copied = false

    var body: some View {
        Form {
            Section(heading: "Key") {
                InfoRow("Name", value: key.name)
                InfoRow("Type", value: key.algorithm.spokenName)
                InfoRow("Face ID or Passcode", value: key.requireUserPresence ? "Required" : "Not required")
            }
            if !key.fingerprintSHA256.isEmpty {
                Section(heading: "Fingerprint") {
                    Text(key.fingerprintSHA256.replacingOccurrences(of: "SHA256:", with: ""))
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                        .accessibilityLabel("SHA-256 fingerprint")
                        .accessibilityValue(SSHHostKey(keyType: "", publicKeyBase64: "", fingerprintSHA256: key.fingerprintSHA256).spokenFingerprint)
                }
            }
            if !key.publicKey.isEmpty {
                Section {
                    Text(key.publicKey)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                        .accessibilityLabel("Public key")
                    Button(copied ? "Copied" : "Copy Public Key") {
                        Clipboard.copy(key.publicKey)
                        copied = true
                    }
                    ShareLink("Share Public Key", item: key.publicKey)
                } header: {
                    SectionHeader("Public Key")
                } footer: {
                    FooterText("Add this line to ~/.ssh/authorized_keys on the server. The public key is safe to share; the private key never leaves this device’s Keychain.")
                }
            }
        }
        .navigationTitle(key.name)
    }
}

/// Generates a key on the device.
struct GenerateKeyView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var type = SSHKeyGenerator.KeyType.ed25519
    @State private var requireUserPresence = false
    @State private var generated: SSHKey?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Group {
                if let generated {
                    KeyDetailView(key: generated)
                } else {
                    Form {
                        Section {
                            TextField("Key Name", text: $name, prompt: Text("For example My iPhone"))
                                .accessibilityLabel("Key Name")
                            ChoicePicker("Type", selection: $type, options: SSHKeyGenerator.KeyType.allCases.map { ChoiceOption($0, $0.displayName) })
                            Toggle("Require Face ID or Passcode", isOn: $requireUserPresence)
                        } footer: {
                            FooterText("Ed25519 works with OpenSSH 6.5 and later, which covers nearly every server. With Face ID or Passcode on, you’ll confirm each time the key is used.")
                        }
                        if let error {
                            Section { Text(error).foregroundStyle(.red) }
                        }
                    }
                }
            }
            .navigationTitle(generated == nil ? "Generate Key" : "Key Created")
            .toolbar {
                if generated == nil {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Generate") {
                            do {
                                generated = try model.keys.generateKey(name: name, type: type, requireUserPresence: requireUserPresence)
                                Announcer.announce("Key created. Copy the public key to add it to your server.")
                            } catch {
                                self.error = error.localizedDescription
                            }
                        }
                    }
                } else {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                }
            }
        }
    }
}

/// Trusted server host keys, with removal.
struct KnownHostsSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var removing: KnownHost?

    var body: some View {
        List {
            if model.knownHosts.entries.isEmpty {
                Text("No trusted host keys yet. Keys are added when you confirm them on first connection.")
            }
            ForEach(model.knownHosts.entries) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.port == 22 ? entry.hostname : "\(entry.hostname), port \(entry.port)").font(.headline)
                    Text(entry.keyType).font(.subheadline)
                    Text(entry.fingerprintSHA256.replacingOccurrences(of: "SHA256:", with: ""))
                        .font(.system(.caption, design: .monospaced))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("Fingerprint")
                        .accessibilityValue(SSHHostKey(keyType: "", publicKeyBase64: "", fingerprintSHA256: entry.fingerprintSHA256).spokenFingerprint)
                }
                .accessibilityElement(children: .combine)
                .swipeActions { Button("Remove", role: .destructive) { removing = entry } }
                .accessibilityAction(named: "Remove") { removing = entry }
            }
        }
        .confirmationDialog("Stop trusting this host key?", isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } }
        ), titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                if let removing { model.knownHosts.remove(removing) }
                removing = nil
            }
        } message: {
            Text("You’ll be asked to verify the key again the next time you connect.")
        }
    }
}
