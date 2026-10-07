import Foundation

/// How a host authenticates. Holds only references: the secrets themselves are stored in
/// the Keychain under the referenced identifiers by `CredentialManager` and `KeyManager`.
public struct AuthenticationConfiguration: Codable, Hashable, Sendable {
    /// Methods to try, in order. The server's advertised list filters this.
    public var methods: [AuthenticationMethod]
    /// Keychain item identifier of a saved password, if the person chose to save one.
    public var savedPasswordID: UUID?
    /// Identifier of an ``SSHKey`` to offer.
    public var keyID: UUID?
    /// Require Face ID, Touch ID, Optic ID or the device passcode before a saved secret is used.
    public var requireUserPresence: Bool

    public init(
        methods: [AuthenticationMethod] = [.publicKey, .keyboardInteractive, .password],
        savedPasswordID: UUID? = nil,
        keyID: UUID? = nil,
        requireUserPresence: Bool = false
    ) {
        self.methods = methods
        self.savedPasswordID = savedPasswordID
        self.keyID = keyID
        self.requireUserPresence = requireUserPresence
    }
}

public enum AuthenticationMethod: String, Codable, CaseIterable, Sendable {
    case publicKey
    case password
    case keyboardInteractive
    /// Keys held by the in-app agent (all unlocked keys are offered in turn).
    case agent

    public var displayName: String {
        switch self {
        case .publicKey: "Public key"
        case .password: "Password"
        case .keyboardInteractive: "Keyboard-interactive"
        case .agent: "Key agent"
        }
    }
}

/// Metadata for a private key. The private material is in the Keychain or Secure Enclave;
/// this struct is safe to persist and export.
public struct SSHKey: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var algorithm: SSHKeyAlgorithm
    /// Public key in OpenSSH `authorized_keys` format: `<type> <base64> [comment]`.
    public var publicKey: String
    /// `SHA256:<base64>` fingerprint, as printed by `ssh-keygen -l`.
    public var fingerprintSHA256: String
    public var storage: SSHKeyStorage
    /// Whether the stored private key is itself passphrase-encrypted.
    public var hasPassphrase: Bool
    public var requireUserPresence: Bool
    public var comment: String
    public var createdAt: Date

    public init(
        id: UUID = UUID(), name: String, algorithm: SSHKeyAlgorithm, publicKey: String,
        fingerprintSHA256: String, storage: SSHKeyStorage, hasPassphrase: Bool = false,
        requireUserPresence: Bool = false, comment: String = "", createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.algorithm = algorithm
        self.publicKey = publicKey
        self.fingerprintSHA256 = fingerprintSHA256
        self.storage = storage
        self.hasPassphrase = hasPassphrase
        self.requireUserPresence = requireUserPresence
        self.comment = comment
        self.createdAt = createdAt
    }
}

public enum SSHKeyAlgorithm: Codable, Hashable, Sendable {
    case ed25519
    case ecdsaP256
    case ecdsaP384
    case ecdsaP521
    case rsa(bits: Int)

    /// The SSH wire name of the key type.
    public var sshName: String {
        switch self {
        case .ed25519: "ssh-ed25519"
        case .ecdsaP256: "ecdsa-sha2-nistp256"
        case .ecdsaP384: "ecdsa-sha2-nistp384"
        case .ecdsaP521: "ecdsa-sha2-nistp521"
        case .rsa: "ssh-rsa"
        }
    }

    public var spokenName: String {
        switch self {
        case .ed25519: "Ed25519"
        case .ecdsaP256: "ECDSA P-256"
        case .ecdsaP384: "ECDSA P-384"
        case .ecdsaP521: "ECDSA P-521"
        case let .rsa(bits): bits > 0 ? "RSA \(bits)-bit" : "RSA"
        }
    }

    /// The Secure Enclave can only hold P-256 keys, so only that algorithm may use it.
    public var supportsSecureEnclave: Bool { self == .ecdsaP256 }
}

public enum SSHKeyStorage: String, Codable, Sendable {
    /// Private key bytes in a Keychain generic-password item (this device only, not synced).
    case keychain
    /// Non-exportable P-256 key generated inside the Secure Enclave.
    case secureEnclave
}

/// A trusted server host key (the in-app equivalent of a `known_hosts` line).
public struct KnownHost: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    /// Host name or address exactly as used to connect.
    public var hostname: String
    public var port: Int
    /// SSH key type, for example `ssh-ed25519`.
    public var keyType: String
    /// Base64 of the public key blob.
    public var publicKeyBase64: String
    public var fingerprintSHA256: String
    public var firstSeen: Date
    public var lastSeen: Date
    public var comment: String

    public init(
        id: UUID = UUID(), hostname: String, port: Int, keyType: String, publicKeyBase64: String,
        fingerprintSHA256: String, firstSeen: Date = Date(), lastSeen: Date = Date(), comment: String = ""
    ) {
        self.id = id
        self.hostname = hostname
        self.port = port
        self.keyType = keyType
        self.publicKeyBase64 = publicKeyBase64
        self.fingerprintSHA256 = fingerprintSHA256
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.comment = comment
    }

    /// The `known_hosts` host field: `host` for port 22, `[host]:port` otherwise.
    public var knownHostsPattern: String {
        port == 22 ? hostname.lowercased() : "[\(hostname.lowercased())]:\(port)"
    }

    /// A line suitable for exporting to an OpenSSH `known_hosts` file.
    public var knownHostsLine: String { "\(knownHostsPattern) \(keyType) \(publicKeyBase64)" }
}

/// Result of checking a presented server key against the trust store.
public enum HostKeyVerdict: Equatable, Sendable {
    /// The key matches a trusted entry.
    case trusted(KnownHost)
    /// No entry exists for this host and port. The person must confirm the fingerprint.
    case unknown
    /// An entry exists with a different key. Never accepted silently: the person must
    /// review a warning and explicitly replace the stored key.
    case changed(previous: KnownHost)
}

/// Pure trust-store lookup. Persistence lives in the app's `KnownHostsStore`.
public enum HostKeyVerifier {
    public static func verdict(
        hostname: String, port: Int, keyType: String, publicKeyBase64: String, knownHosts: [KnownHost]
    ) -> HostKeyVerdict {
        let host = hostname.lowercased()
        let candidates = knownHosts.filter { $0.hostname.lowercased() == host && $0.port == port }
        if let match = candidates.first(where: { $0.keyType == keyType && $0.publicKeyBase64 == publicKeyBase64 }) {
            return .trusted(match)
        }
        // A different key of the same type is a changed key. A key of a type we have never
        // seen for this host is also treated as changed when any key is already trusted,
        // so that a downgrade to a different algorithm cannot slip through as "unknown".
        if let previous = candidates.first(where: { $0.keyType == keyType }) ?? candidates.first {
            return .changed(previous: previous)
        }
        return .unknown
    }
}

/// A port forward attached to a host.
public struct PortForward: Identifiable, Codable, Hashable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        /// `-L`: listen on this device, connect from the server.
        case local
        /// `-R`: listen on the server, connect from this device.
        case remote
        /// `-D`: SOCKS proxy listening on this device.
        case dynamic
    }

    public var id: UUID
    public var kind: Kind
    public var label: String
    public var bindAddress: String
    public var bindPort: Int
    /// Ignored for dynamic forwards.
    public var destinationHost: String
    public var destinationPort: Int
    public var isEnabled: Bool

    public init(
        id: UUID = UUID(), kind: Kind, label: String = "", bindAddress: String = "127.0.0.1",
        bindPort: Int, destinationHost: String = "", destinationPort: Int = 0, isEnabled: Bool = true
    ) {
        self.id = id
        self.kind = kind
        self.label = label
        self.bindAddress = bindAddress
        self.bindPort = bindPort
        self.destinationHost = destinationHost
        self.destinationPort = destinationPort
        self.isEnabled = isEnabled
    }

    /// Spoken/visible description, for example "Local port 8080 to db.internal port 5432".
    public var summary: String {
        switch kind {
        case .local: "Local port \(bindPort) to \(destinationHost) port \(destinationPort)"
        case .remote: "Server port \(bindPort) to \(destinationHost) port \(destinationPort)"
        case .dynamic: "SOCKS proxy on local port \(bindPort)"
        }
    }
}
