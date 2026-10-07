import Foundation
import CryptoKit

/// Reads metadata from private key text without decrypting it, so the UI can ask for a
/// passphrase before trying (and failing) to authenticate.
public enum PrivateKeyInspector {
    public enum Format: Equatable, Sendable {
        case openSSH
        case pem(label: String)
        case unknown
    }

    public static func format(of text: String) -> Format {
        if text.contains("-----BEGIN OPENSSH PRIVATE KEY-----") { return .openSSH }
        if let range = text.range(of: "-----BEGIN "), let end = text.range(of: "-----", range: range.upperBound..<text.endIndex) {
            return .pem(label: String(text[range.upperBound..<end.lowerBound]))
        }
        return .unknown
    }

    /// Whether the key is protected by a passphrase.
    public static func isEncrypted(_ text: String) -> Bool {
        switch format(of: text) {
        case .openSSH:
            return openSSHCipherName(text).map { $0 != "none" } ?? false
        case let .pem(label):
            return label.contains("ENCRYPTED") || text.contains("Proc-Type: 4,ENCRYPTED")
        case .unknown:
            return false
        }
    }

    /// The key type recorded in an OpenSSH key's public section, such as `ssh-ed25519`.
    public static func openSSHKeyType(_ text: String) -> String? {
        guard var reader = openSSHReader(text) else { return nil }
        _ = reader.string()          // cipher
        _ = reader.string()          // kdf
        _ = reader.string()          // kdf options
        guard reader.uint32() == 1, let publicBlob = reader.string() else { return nil }
        var publicReader = ByteReader(bytes: publicBlob)
        return publicReader.string().map { String(decoding: $0, as: UTF8.self) }
    }

    /// The public half of an OpenSSH private key: its type, the wire-format blob, the
    /// `authorized_keys` line and the SHA-256 fingerprint. `nil` for other formats.
    public static func openSSHPublicKey(_ text: String) -> (type: String, authorizedKeysLine: String, fingerprintSHA256: String)? {
        guard var reader = openSSHReader(text) else { return nil }
        _ = reader.string()
        _ = reader.string()
        _ = reader.string()
        guard reader.uint32() == 1, let blob = reader.string() else { return nil }
        var publicReader = ByteReader(bytes: blob)
        guard let typeBytes = publicReader.string() else { return nil }
        let type = String(decoding: typeBytes, as: UTF8.self)
        var fingerprint = Data(SHA256.hash(data: Data(blob))).base64EncodedString()
        while fingerprint.hasSuffix("=") { fingerprint.removeLast() }
        return (type, "\(type) \(Data(blob).base64EncodedString())", "SHA256:\(fingerprint)")
    }

    private static func openSSHCipherName(_ text: String) -> String? {
        guard var reader = openSSHReader(text), let cipher = reader.string() else { return nil }
        return String(decoding: cipher, as: UTF8.self)
    }

    private static func openSSHReader(_ text: String) -> ByteReader? {
        let body = text
            .components(separatedBy: "\n")
            .filter { !$0.hasPrefix("-----") }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = Data(base64Encoded: body, options: .ignoreUnknownCharacters) else { return nil }
        let magic = Array("openssh-key-v1".utf8) + [0]
        let bytes = [UInt8](data)
        guard bytes.starts(with: magic) else { return nil }
        return ByteReader(bytes: Array(bytes.dropFirst(magic.count)))
    }

    private struct ByteReader {
        let bytes: [UInt8]
        var offset = 0

        mutating func uint32() -> UInt32? {
            guard offset + 4 <= bytes.count else { return nil }
            defer { offset += 4 }
            return bytes[offset..<offset + 4].reduce(0) { $0 << 8 | UInt32($1) }
        }

        mutating func string() -> [UInt8]? {
            guard let length = uint32(), offset + Int(length) <= bytes.count else { return nil }
            defer { offset += Int(length) }
            return Array(bytes[offset..<offset + Int(length)])
        }
    }
}
