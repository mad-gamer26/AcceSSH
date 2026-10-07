import Foundation
import Security
import LocalAuthentication
import Observation
import AcceSSHCore
import AcceSSHTransport

/// Reads and writes a Codable value as JSON in Application Support/AcceSSH.
/// Only non-secret data is stored this way; secrets go to ``Keychain``.
struct JSONFileStore<Value: Codable> {
    let url: URL

    init(fileName: String) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AcceSSH", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        url = base.appendingPathComponent(fileName)
    }

    func load() -> Value? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Value.self, from: data)
    }

    func save(_ value: Value) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(value).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            assertionFailure("Could not save \(url.lastPathComponent): \(error)")
        }
    }
}

/// Keychain storage for passwords and private keys.
///
/// Items use `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`: they never sync to iCloud and are
/// readable only while the device is unlocked.
enum Keychain {
    enum Kind: String {
        case password = "com.matthewdovi.AcceSSH.password"
        case privateKey = "com.matthewdovi.AcceSSH.private-key"
        case passphrase = "com.matthewdovi.AcceSSH.passphrase"
    }

    /// Stores a secret. With `requireUserPresence`, reading it later requires Face ID, Touch ID,
    /// Optic ID or the device passcode.
    static func set(_ secret: String, kind: Kind, id: UUID, requireUserPresence: Bool = false) -> Bool {
        delete(kind: kind, id: id)
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: kind.rawValue,
            kSecAttrAccount as String: id.uuidString,
            kSecValueData as String: Data(secret.utf8),
        ]
        if requireUserPresence,
           let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .userPresence, nil) {
            query[kSecAttrAccessControl as String] = access
        } else {
            query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        }
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    /// Reads a secret. May show a Face ID or passcode prompt, so call it off the main thread.
    nonisolated static func get(kind: Kind, id: UUID, reason: String? = nil) -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: kind.rawValue,
            kSecAttrAccount as String: id.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if let reason {
            let context = LAContext()
            context.localizedReason = reason
            query[kSecUseAuthenticationContext as String] = context
        }
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func delete(kind: Kind, id: UUID) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: kind.rawValue,
            kSecAttrAccount as String: id.uuidString,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

/// Saved hosts and groups.
@MainActor @Observable
final class HostStore {
    private(set) var hosts: [Host]
    @ObservationIgnored private let file = JSONFileStore<[Host]>(fileName: "hosts.json")

    init() {
        hosts = file.load() ?? []
    }

    func save(_ host: Host) {
        if let index = hosts.firstIndex(where: { $0.id == host.id }) {
            hosts[index] = host
        } else {
            hosts.append(host)
        }
        persist()
    }

    func delete(_ host: Host) {
        hosts.removeAll { $0.id == host.id }
        if let passwordID = host.authentication.savedPasswordID {
            Keychain.delete(kind: .password, id: passwordID)
        }
        persist()
    }

    func markConnected(_ hostID: UUID) {
        guard let index = hosts.firstIndex(where: { $0.id == hostID }) else { return }
        hosts[index].lastConnectedAt = Date()
        persist()
    }

    var sortedHosts: [Host] {
        hosts.sorted { lhs, rhs in
            if lhs.isFavorite != rhs.isFavorite { return lhs.isFavorite }
            return lhs.effectiveDisplayName.localizedStandardCompare(rhs.effectiveDisplayName) == .orderedAscending
        }
    }

    private func persist() { file.save(hosts) }
}

/// Imported private keys: metadata on disk, key material in the Keychain.
@MainActor @Observable
final class KeyStore {
    private(set) var keys: [SSHKey]
    @ObservationIgnored private let file = JSONFileStore<[SSHKey]>(fileName: "keys.json")

    init() {
        keys = file.load() ?? []
    }

    enum ImportError: LocalizedError {
        case unrecognized
        case keychainFailed

        var errorDescription: String? {
            switch self {
            case .unrecognized: "That doesn’t look like a private key. Private keys begin with a line such as “-----BEGIN OPENSSH PRIVATE KEY-----”."
            case .keychainFailed: "The key couldn’t be saved to the Keychain."
            }
        }
    }

    /// Imports private key text. Returns the stored key's metadata.
    func importKey(name: String, privateKey text: String) throws -> SSHKey {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        let format = PrivateKeyInspector.format(of: trimmed)
        guard format != .unknown, trimmed.contains("PRIVATE KEY") else { throw ImportError.unrecognized }
        let publicInfo = PrivateKeyInspector.openSSHPublicKey(trimmed)
        let algorithm: SSHKeyAlgorithm = switch publicInfo?.type ?? "" {
        case "ssh-ed25519": .ed25519
        case "ecdsa-sha2-nistp256": .ecdsaP256
        case "ecdsa-sha2-nistp384": .ecdsaP384
        case "ecdsa-sha2-nistp521": .ecdsaP521
        default: .rsa(bits: 0)
        }
        let key = SSHKey(
            name: name.isEmpty ? "Imported key" : name, algorithm: algorithm,
            publicKey: publicInfo?.authorizedKeysLine ?? "", fingerprintSHA256: publicInfo?.fingerprintSHA256 ?? "",
            storage: .keychain, hasPassphrase: PrivateKeyInspector.isEncrypted(trimmed)
        )
        guard Keychain.set(trimmed, kind: .privateKey, id: key.id) else { throw ImportError.keychainFailed }
        keys.append(key)
        file.save(keys)
        return key
    }

    /// Generates a new key pair on this device. The private key goes straight into the Keychain.
    func generateKey(name: String, type: SSHKeyGenerator.KeyType, requireUserPresence: Bool) throws -> SSHKey {
        let comment = name.isEmpty ? "AcceSSH" : "\(name) (AcceSSH)"
        let generated = SSHKeyGenerator.generate(type, comment: comment)
        let key = SSHKey(
            name: name.isEmpty ? "AcceSSH Key" : name,
            algorithm: type == .ed25519 ? .ed25519 : .ecdsaP256,
            publicKey: generated.authorizedKeysLine, fingerprintSHA256: generated.fingerprintSHA256,
            storage: .keychain, hasPassphrase: false, requireUserPresence: requireUserPresence, comment: comment
        )
        guard Keychain.set(generated.privateKeyPEM, kind: .privateKey, id: key.id, requireUserPresence: requireUserPresence) else {
            throw ImportError.keychainFailed
        }
        keys.append(key)
        file.save(keys)
        return key
    }

    /// Loads private key text off the main thread (it may require Face ID).
    func privateKey(for key: SSHKey) async -> String? {
        let id = key.id
        let reason = "Use the key “\(key.name)” to sign in."
        return await Task.detached { Keychain.get(kind: .privateKey, id: id, reason: reason) }.value
    }

    func delete(_ key: SSHKey) {
        Keychain.delete(kind: .privateKey, id: key.id)
        Keychain.delete(kind: .passphrase, id: key.id)
        keys.removeAll { $0.id == key.id }
        file.save(keys)
    }

    func key(id: UUID?) -> SSHKey? {
        guard let id else { return nil }
        return keys.first { $0.id == id }
    }
}

/// Trusted server host keys.
@MainActor @Observable
final class KnownHostsStore {
    private(set) var entries: [KnownHost]
    @ObservationIgnored private let file = JSONFileStore<[KnownHost]>(fileName: "known-hosts.json")

    init() {
        entries = file.load() ?? []
    }

    func verdict(hostname: String, port: Int, key: SSHHostKey) -> HostKeyVerdict {
        HostKeyVerifier.verdict(hostname: hostname, port: port, keyType: key.keyType,
                                publicKeyBase64: key.publicKeyBase64, knownHosts: entries)
    }

    /// Trusts a key. Any previous key for the same host and port is replaced; callers must
    /// only do this after the person explicitly approved the change.
    func trust(hostname: String, port: Int, key: SSHHostKey) {
        entries.removeAll { $0.hostname.lowercased() == hostname.lowercased() && $0.port == port }
        entries.append(KnownHost(hostname: hostname, port: port, keyType: key.keyType,
                                 publicKeyBase64: key.publicKeyBase64, fingerprintSHA256: key.fingerprintSHA256))
        file.save(entries)
    }

    func touch(_ entry: KnownHost) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[index].lastSeen = Date()
        file.save(entries)
    }

    func remove(_ entry: KnownHost) {
        entries.removeAll { $0.id == entry.id }
        file.save(entries)
    }
}
