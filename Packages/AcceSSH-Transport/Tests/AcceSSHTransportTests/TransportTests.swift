import Foundation
import Testing
@testable import AcceSSHTransport
import AcceSSHTerminal

/// Live tests run only when a test server is configured through the environment:
///
///     ACCESSH_TEST_HOST=example.com ACCESSH_TEST_USER=me \
///     ACCESSH_TEST_KEY=~/.ssh/id_ed25519 swift test
///
/// Optional: ACCESSH_TEST_FINGERPRINTS (comma-separated SHA256:… values) to pin host keys.
/// Credentials are read at run time and never stored in the repository.
enum LiveServer {
    static let environment = ProcessInfo.processInfo.environment
    static var host: String? { environment["ACCESSH_TEST_HOST"] }
    static var user: String { environment["ACCESSH_TEST_USER"] ?? NSUserName() }
    static var keyPath: String? { environment["ACCESSH_TEST_KEY"].map { NSString(string: $0).expandingTildeInPath } }
    static var fingerprints: [String] { environment["ACCESSH_TEST_FINGERPRINTS"]?.split(separator: ",").map(String.init) ?? [] }
    static var isConfigured: Bool { host != nil && keyPath != nil }

    static func connectAndAuthenticate() async throws -> SSHConnection {
        let connection = SSHConnection(host: host!, connectTimeout: 15)
        _ = try await connection.connect()
        let key = try String(contentsOfFile: keyPath!, encoding: .utf8)
        try await connection.authenticate(username: user, privateKey: key, passphrase: nil)
        return connection
    }
}

@Suite("Live SSH server", .enabled(if: LiveServer.isConfigured), .serialized)
struct LiveServerTests {
    @Test func handshakePresentsAPinnedHostKey() async throws {
        let connection = SSHConnection(host: LiveServer.host!)
        let key = try await connection.connect()
        #expect(key.fingerprintSHA256.hasPrefix("SHA256:"))
        #expect(!key.keyType.isEmpty && key.keyType != "unknown")
        if !LiveServer.fingerprints.isEmpty {
            #expect(LiveServer.fingerprints.contains(key.fingerprintSHA256), "Unexpected host key \(key.fingerprintSHA256)")
        }
        let methods = try await connection.authenticationMethods(username: LiveServer.user)
        #expect(methods.contains("publickey"))
        connection.disconnect()
    }

    @Test func runsACommandAndReportsExitStatus() async throws {
        let connection = try await LiveServer.connectAndAuthenticate()
        let result = try await connection.execute("echo accessh; echo oops >&2; exit 3")
        #expect(result.outputText == "accessh\n")
        #expect(result.errorText == "oops\n")
        #expect(result.exitStatus == 3)
        connection.disconnect()
    }

    @Test func interactiveShellDrivesTheEmulator() async throws {
        let connection = try await LiveServer.connectAndAuthenticate()
        let shell = try await connection.openShell(SSHShellRequest(columns: 100, rows: 30))
        let terminal = TerminalEmulator(columns: 100, rows: 30)

        let reader = Task { () -> String in
            var collected = Data()
            for await chunk in shell.output {
                collected.append(chunk)
                if String(decoding: collected, as: UTF8.self).contains("ACCESS_42") { break }
            }
            return String(decoding: collected, as: UTF8.self)
        }
        try await shell.write(Data("echo ACCESS_$((6*7))\n".utf8))
        let timeout = Task {
            try await Task.sleep(for: .seconds(15))
            reader.cancel()
        }
        let text = await reader.value
        timeout.cancel()
        terminal.feed(Array(text.utf8))
        #expect(terminal.fullText().contains("ACCESS_42"))

        try await shell.resize(columns: 120, rows: 40)
        try await shell.write(Data("exit\n".utf8))
        for await _ in shell.output {}  // Drains until the server closes the channel.
        #expect(await shell.exitStatus() == 0)
        connection.disconnect()
    }

    @Test func wrongKeyIsRejectedWithAClearError() async throws {
        let connection = SSHConnection(host: LiveServer.host!)
        _ = try await connection.connect()
        // A freshly generated, unregistered key in OpenSSH format.
        let unregistered = try Self.generateUnregisteredKey()
        await #expect(throws: SSHError.authenticationFailed(method: "key")) {
            try await connection.authenticate(username: LiveServer.user, privateKey: unregistered, passphrase: nil)
        }
        connection.disconnect()
    }

    static func generateUnregisteredKey() throws -> String {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("key").path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        process.arguments = ["-q", "-t", "ed25519", "-N", "", "-f", path]
        try process.run()
        process.waitUntilExit()
        return try String(contentsOfFile: path, encoding: .utf8)
    }
}

@Suite("Transport failures")
struct TransportFailureTests {
    @Test func refusedConnectionIsExplained() async {
        let connection = SSHConnection(host: "127.0.0.1", port: 1, connectTimeout: 5)
        do {
            _ = try await connection.connect()
            Issue.record("connected unexpectedly")
        } catch let error as SSHError {
            switch error {
            case .connectionRefused(_, 1), .connectionTimedOut: break
            default: Issue.record("unexpected error \(error)")
            }
            #expect(!error.userMessage.isEmpty)
        } catch {
            Issue.record("unexpected error type \(error)")
        }
    }

    @Test func unknownHostIsExplained() async {
        let connection = SSHConnection(host: "no-such-host.invalid", connectTimeout: 5)
        await #expect(throws: SSHError.self) { _ = try await connection.connect() }
    }

    @Test func operationsAfterDisconnectFail() async throws {
        let connection = SSHConnection(host: "127.0.0.1", port: 1, connectTimeout: 2)
        connection.disconnect()
        await #expect(throws: SSHError.self) { _ = try await connection.connect() }
    }

    @Test func detectsEncryptedKeys() throws {
        let plain = try LiveServerTests.generateUnregisteredKey()
        #expect(!PrivateKeyInspector.isEncrypted(plain))
        #expect(PrivateKeyInspector.openSSHKeyType(plain) == "ssh-ed25519")
        #expect(PrivateKeyInspector.isEncrypted("-----BEGIN RSA PRIVATE KEY-----\nProc-Type: 4,ENCRYPTED\n-----END RSA PRIVATE KEY-----"))
    }

    @Test func fingerprintsAreSpokenInGroups() {
        let key = SSHHostKey(keyType: "ssh-ed25519", publicKeyBase64: "", fingerprintSHA256: "SHA256:abcdEFGHij")
        #expect(key.spokenFingerprint == "abcd EFGH ij")
    }
}

@Suite("Key generation")
struct KeyGenerationTests {
    /// `ssh-keygen -y` must derive exactly our public key from our private key file.
    @Test(arguments: SSHKeyGenerator.KeyType.allCases)
    func generatedKeysAreValidOpenSSHKeys(_ type: SSHKeyGenerator.KeyType) throws {
        let key = SSHKeyGenerator.generate(type, comment: "accessh-test")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("key")
        try key.privateKeyPEM.write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)

        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        process.arguments = ["-y", "-f", path.path]
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let derived = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(process.terminationStatus == 0)
        #expect(key.authorizedKeysLine == derived)

        #expect(PrivateKeyInspector.openSSHPublicKey(key.privateKeyPEM)?.fingerprintSHA256 == key.fingerprintSHA256)
        #expect(!PrivateKeyInspector.isEncrypted(key.privateKeyPEM))
    }

    /// libssh2 must load the key: an unregistered key is *rejected by the server*, not unreadable.
    @Test(.enabled(if: LiveServer.isConfigured), arguments: SSHKeyGenerator.KeyType.allCases)
    func libssh2LoadsGeneratedKeys(_ type: SSHKeyGenerator.KeyType) async throws {
        let key = SSHKeyGenerator.generate(type, comment: "")
        let connection = SSHConnection(host: LiveServer.host!)
        _ = try await connection.connect()
        await #expect(throws: SSHError.authenticationFailed(method: "key")) {
            try await connection.authenticate(username: LiveServer.user, privateKey: key.privateKeyPEM, passphrase: nil)
        }
        connection.disconnect()
    }
}
