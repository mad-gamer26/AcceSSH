import Foundation
import CryptoKit

/// Generates SSH key pairs with CryptoKit and encodes them in OpenSSH's standard
/// `openssh-key-v1` private-key format (unencrypted; AcceSSH protects the stored key with
/// the Keychain instead of a passphrase). Only encoding happens here — all cryptography is
/// CryptoKit's.
public enum SSHKeyGenerator {
    public enum KeyType: String, CaseIterable, Sendable, Identifiable {
        case ed25519
        case ecdsaP256

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .ed25519: "Ed25519 (recommended)"
            case .ecdsaP256: "ECDSA P-256"
            }
        }
    }

    public struct GeneratedKey: Sendable {
        public var type: KeyType
        /// `-----BEGIN OPENSSH PRIVATE KEY-----` text.
        public var privateKeyPEM: String
        /// `authorized_keys` line, including the comment.
        public var authorizedKeysLine: String
        public var fingerprintSHA256: String
    }

    public static func generate(_ type: KeyType, comment: String) -> GeneratedKey {
        let publicBlob: Data
        let privateFields: Data
        switch type {
        case .ed25519:
            let key = Curve25519.Signing.PrivateKey()
            let publicKey = key.publicKey.rawRepresentation
            publicBlob = encodeString("ssh-ed25519") + encodeString(publicKey)
            // OpenSSH stores the 32-byte seed followed by the 32-byte public key.
            privateFields = encodeString("ssh-ed25519") + encodeString(publicKey)
                + encodeString(key.rawRepresentation + publicKey)
        case .ecdsaP256:
            let key = P256.Signing.PrivateKey()
            let point = key.publicKey.x963Representation
            publicBlob = encodeString("ecdsa-sha2-nistp256") + encodeString("nistp256") + encodeString(point)
            privateFields = encodeString("ecdsa-sha2-nistp256") + encodeString("nistp256") + encodeString(point)
                + encodeMPInt(key.rawRepresentation)
        }

        var checkBytes = [UInt8](repeating: 0, count: 4)
        _ = SecRandomCopyBytes(kSecRandomDefault, 4, &checkBytes)
        var privateSection = Data(checkBytes) + Data(checkBytes) + privateFields + encodeString(comment)
        var pad: UInt8 = 1
        while privateSection.count % 8 != 0 {
            privateSection.append(pad)
            pad += 1
        }

        var body = Data("openssh-key-v1".utf8) + Data([0])
        body += encodeString("none") + encodeString("none") + encodeString(Data())
        body += encodeUInt32(1) + encodeString(publicBlob) + encodeString(privateSection)

        let base64 = body.base64EncodedString()
        var lines: [String] = []
        var index = base64.startIndex
        while index < base64.endIndex {
            let end = base64.index(index, offsetBy: 70, limitedBy: base64.endIndex) ?? base64.endIndex
            lines.append(String(base64[index..<end]))
            index = end
        }
        let pem = (["-----BEGIN OPENSSH PRIVATE KEY-----"] + lines + ["-----END OPENSSH PRIVATE KEY-----"]).joined(separator: "\n") + "\n"

        let typeName = type == .ed25519 ? "ssh-ed25519" : "ecdsa-sha2-nistp256"
        var fingerprint = Data(SHA256.hash(data: publicBlob)).base64EncodedString()
        while fingerprint.hasSuffix("=") { fingerprint.removeLast() }
        let line = "\(typeName) \(publicBlob.base64EncodedString())" + (comment.isEmpty ? "" : " \(comment)")
        return GeneratedKey(type: type, privateKeyPEM: pem, authorizedKeysLine: line, fingerprintSHA256: "SHA256:\(fingerprint)")
    }

    private static func encodeUInt32(_ value: UInt32) -> Data {
        Data([UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)])
    }

    private static func encodeString(_ data: Data) -> Data {
        encodeUInt32(UInt32(data.count)) + data
    }

    private static func encodeString(_ text: String) -> Data {
        encodeString(Data(text.utf8))
    }

    /// SSH `mpint`: big-endian, minimal, with a leading zero when the high bit is set.
    private static func encodeMPInt(_ bytes: Data) -> Data {
        var value = Data(bytes.drop { $0 == 0 })
        if let first = value.first, first & 0x80 != 0 { value.insert(0, at: 0) }
        return encodeString(value)
    }
}
