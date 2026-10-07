import Foundation
import CryptoKit
import CLibSSH2
import AcceSSHCore

/// The server's host key, presented for verification before authentication.
public struct SSHHostKey: Sendable, Equatable {
    /// SSH key type, for example `ssh-ed25519`.
    public var keyType: String
    public var publicKeyBase64: String
    /// `SHA256:<base64>` as printed by `ssh-keygen -l`.
    public var fingerprintSHA256: String

    public init(keyType: String, publicKeyBase64: String, fingerprintSHA256: String) {
        self.keyType = keyType
        self.publicKeyBase64 = publicKeyBase64
        self.fingerprintSHA256 = fingerprintSHA256
    }

    /// The fingerprint grouped for speech: VoiceOver reads short groups more clearly than one long token.
    public var spokenFingerprint: String {
        let body = fingerprintSHA256.replacingOccurrences(of: "SHA256:", with: "")
        var groups: [String] = []
        var current = ""
        for character in body {
            current.append(character)
            if current.count == 4 {
                groups.append(current)
                current = ""
            }
        }
        if !current.isEmpty { groups.append(current) }
        return groups.joined(separator: " ")
    }
}

public enum SSHConnectionEvent: Sendable, Equatable {
    /// The session ended. `nil` means it was closed deliberately.
    case disconnected(SSHError?)
}

/// A keyboard-interactive round: the server's questions.
public struct SSHKeyboardInteractiveChallenge: Sendable, Equatable {
    public struct Prompt: Sendable, Equatable {
        public var text: String
        /// `false` for secrets: the answer must be entered in a secure field and never shown or spoken.
        public var echo: Bool
    }

    public var name: String
    public var instruction: String
    public var prompts: [Prompt]
}

/// Answers a challenge, or returns `nil` if the person cancelled.
public typealias SSHKeyboardInteractiveResponder = @Sendable (SSHKeyboardInteractiveChallenge) async -> [String]?

public struct SSHShellRequest: Sendable {
    public var terminalType: String
    public var columns: Int
    public var rows: Int
    /// Variables the server is asked to set; it ignores names not in its `AcceptEnv`.
    public var environment: [(name: String, value: String)]

    public init(terminalType: String = "xterm-256color", columns: Int = 80, rows: Int = 24,
                environment: [(name: String, value: String)] = []) {
        self.terminalType = terminalType
        self.columns = columns
        self.rows = rows
        self.environment = environment
    }
}

public struct SSHCommandResult: Sendable {
    public var output: Data
    public var errorOutput: Data
    public var exitStatus: Int32?

    public var outputText: String { String(decoding: output, as: UTF8.self) }
    public var errorText: String { String(decoding: errorOutput, as: UTF8.self) }
}

/// One SSH connection. Create it, call ``connect()``, verify the returned host key, then
/// authenticate and open channels. All methods are safe to call from any task.
public final class SSHConnection: Sendable {
    let loop: SSHSessionLoop
    public let host: String
    public let port: Int

    /// Connection lifecycle events. Iterate from one task only.
    public var events: AsyncStream<SSHConnectionEvent> { loop.events }

    public init(host: String, port: Int = 22, connectTimeout: TimeInterval = 15, keepAliveInterval: TimeInterval? = 30,
                compression: Bool = false, addressFamily: AddressFamilyPreference = .automatic) {
        self.host = host
        self.port = port
        let transport = NetworkTransport(host: host, port: port, addressFamily: addressFamily, connectTimeout: connectTimeout)
        loop = SSHSessionLoop(host: host, port: port, connectTimeout: connectTimeout, keepAliveInterval: keepAliveInterval,
                              useCompression: compression, transport: transport)
    }

    /// Creates a connection configured from a saved host.
    public convenience init(host: AcceSSHCore.Host) {
        self.init(host: host.hostname, port: host.port, connectTimeout: host.connection.connectTimeout,
                  keepAliveInterval: host.connection.keepAliveInterval, compression: host.connection.compression,
                  addressFamily: host.connection.addressFamily)
    }

    deinit {
        loop.shutdown()
    }

    // MARK: - Connecting

    /// Opens the TCP connection and performs the SSH handshake. Returns the server's host key,
    /// which the caller must verify (see `HostKeyVerifier`) before authenticating.
    public func connect() async throws -> SSHHostKey {
        loop.start()
        let state = ConnectState(deadline: Date().addingTimeInterval(loop.connectTimeout))
        return try await loop.perform { loop -> SSHHostKey? in
            switch state.stage {
            case .startTransport:
                let weakLoop = WeakLoop(loop)
                loop.transport.start { weakLoop.value?.signal() }
                state.stage = .waitTransport
                return nil
            case .waitTransport:
                switch loop.transport.state {
                case .ready:
                    try loop.createSession()
                    state.stage = .handshake
                case let .failed(error):
                    throw error
                default:
                    if Date() >= state.deadline {
                        throw loop.transport.pendingConnectError
                            ?? SSHError.connectionTimedOut(host: loop.host, seconds: Int(loop.connectTimeout))
                    }
                    return nil
                }
                fallthrough
            case .handshake:
                guard let session = loop.session else { throw SSHError.notConnected }
                let result = libssh2_session_handshake(session, loop.placeholderSocket)
                if result == LIBSSH2_ERROR_EAGAIN {
                    if Date() >= state.deadline {
                        throw SSHError.connectionTimedOut(host: loop.host, seconds: Int(loop.connectTimeout))
                    }
                    return nil
                }
                if result != 0 {
                    if case let .failed(error) = loop.transport.state { throw error }
                    throw SSHError.handshakeFailed(detail: loop.lastErrorMessage())
                }
                return try Self.hostKey(of: session)
            }
        }
    }

    private static func hostKey(of session: OpaquePointer) throws -> SSHHostKey {
        var length = 0
        var type: Int32 = 0
        guard let key = libssh2_session_hostkey(session, &length, &type), length > 0 else {
            throw SSHError.hostKeyUnavailable
        }
        let blob = Data(bytes: key, count: length)
        let typeName: String = switch type {
        case LIBSSH2_HOSTKEY_TYPE_RSA: "ssh-rsa"
        case LIBSSH2_HOSTKEY_TYPE_ECDSA_256: "ecdsa-sha2-nistp256"
        case LIBSSH2_HOSTKEY_TYPE_ECDSA_384: "ecdsa-sha2-nistp384"
        case LIBSSH2_HOSTKEY_TYPE_ECDSA_521: "ecdsa-sha2-nistp521"
        case LIBSSH2_HOSTKEY_TYPE_ED25519: "ssh-ed25519"
        default: "unknown"
        }
        var fingerprint = Data(SHA256.hash(data: blob)).base64EncodedString()
        while fingerprint.hasSuffix("=") { fingerprint.removeLast() }
        return SSHHostKey(keyType: typeName, publicKeyBase64: blob.base64EncodedString(), fingerprintSHA256: "SHA256:\(fingerprint)")
    }

    // MARK: - Authentication

    /// Methods the server accepts for `username` (wire names such as `publickey`). Returns an
    /// empty array if the server accepted the user without authentication.
    public func authenticationMethods(username: String) async throws -> [String] {
        try await loop.perform { loop -> [String]? in
            guard let session = loop.session else { throw SSHError.notConnected }
            let list = username.withCString { libssh2_userauth_list(session, $0, UInt32(strlen($0))) }
            if let list { return String(cString: list).split(separator: ",").map(String.init) }
            if libssh2_userauth_authenticated(session) != 0 {
                loop.didAuthenticate()
                return []
            }
            if loop.lastErrorCode == LIBSSH2_ERROR_EAGAIN { return nil }
            throw SSHError.protocolError(code: loop.lastErrorCode, detail: loop.lastErrorMessage())
        }
    }

    public func authenticate(username: String, password: String) async throws {
        let _: Bool = try await loop.perform { loop in
            guard let session = loop.session else { throw SSHError.notConnected }
            let result = username.withCString { user in
                password.withCString { secret in
                    libssh2_userauth_password_ex(session, user, UInt32(strlen(user)), secret, UInt32(strlen(secret)), nil)
                }
            }
            try loop.check(result) { code, message in Self.authenticationError(code, message, method: "password") }
            loop.didAuthenticate()
            return true
        }
    }

    /// Authenticates with a private key in OpenSSH or PEM format (Ed25519, ECDSA, RSA;
    /// passphrase-protected keys are supported).
    public func authenticate(username: String, privateKey: String, passphrase: String?) async throws {
        if passphrase == nil, PrivateKeyInspector.isEncrypted(privateKey) {
            throw SSHError.passphraseRequired
        }
        let _: Bool = try await loop.perform { loop in
            guard let session = loop.session else { throw SSHError.notConnected }
            let result = username.withCString { user in
                privateKey.withCString { key in
                    (passphrase ?? "").withCString { secret in
                        libssh2_userauth_publickey_frommemory(session, user, strlen(user), nil, 0, key, strlen(key),
                                                              passphrase == nil ? nil : secret)
                    }
                }
            }
            try loop.check(result) { code, message in
                if code == LIBSSH2_ERROR_FILE || code == LIBSSH2_ERROR_METHOD_NOT_SUPPORTED {
                    return passphrase != nil && message.localizedCaseInsensitiveContains("passphrase")
                        ? .authenticationFailed(method: "key passphrase")
                        : .privateKeyUnreadable(detail: message)
                }
                return Self.authenticationError(code, message, method: "key")
            }
            loop.didAuthenticate()
            return true
        }
    }

    /// Keyboard-interactive authentication (one-time codes, PAM prompts, password prompts).
    /// The responder is called once per round with the server's questions.
    public func authenticateKeyboardInteractive(username: String, responder: @escaping SSHKeyboardInteractiveResponder) async throws {
        let context = KeyboardInteractiveContext(responder: responder)
        let _: Bool = try await loop.perform { loop in
            guard let session = loop.session else { throw SSHError.notConnected }
            loop.keyboardInteractive = context
            let result = username.withCString { user in
                libssh2_userauth_keyboard_interactive_ex(session, user, UInt32(strlen(user)), keyboardInteractiveCallback)
            }
            if result == LIBSSH2_ERROR_EAGAIN { return nil }
            loop.keyboardInteractive = nil
            if context.wasCancelled { throw SSHError.cancelled }
            try loop.check(result) { code, message in Self.authenticationError(code, message, method: "response") }
            loop.didAuthenticate()
            return true
        }
    }

    private static func authenticationError(_ code: Int32, _ message: String, method: String) -> SSHError {
        switch code {
        case LIBSSH2_ERROR_AUTHENTICATION_FAILED, LIBSSH2_ERROR_PUBLICKEY_UNVERIFIED:
            .authenticationFailed(method: method)
        case LIBSSH2_ERROR_SOCKET_DISCONNECT, LIBSSH2_ERROR_SOCKET_SEND, LIBSSH2_ERROR_SOCKET_RECV:
            .connectionLost(detail: message)
        default:
            .protocolError(code: code, detail: message)
        }
    }

    // MARK: - Channels

    /// Opens an interactive shell on a pseudo-terminal.
    public func openShell(_ request: SSHShellRequest) async throws -> SSHChannel {
        try await openChannel(pty: request, command: nil)
    }

    /// Runs a command without a PTY and collects its output. `input`, when given, is written to
    /// the command's standard input, which is then closed.
    public func execute(_ command: String, input: Data? = nil) async throws -> SSHCommandResult {
        let channel = try await openChannel(pty: nil, command: command)
        if let input {
            try await channel.write(input)
            try await channel.sendEOF()
        }
        async let output = Self.collect(channel.output)
        async let errors = Self.collect(channel.errorOutput)
        let (out, err) = await (output, errors)
        return SSHCommandResult(output: out, errorOutput: err, exitStatus: await channel.exitStatus())
    }

    private static func collect(_ stream: AsyncStream<Data>?) async -> Data {
        guard let stream else { return Data() }
        var result = Data()
        for await chunk in stream { result.append(chunk) }
        return result
    }

    private func openChannel(pty: SSHShellRequest?, command: String?) async throws -> SSHChannel {
        let (output, outputContinuation) = AsyncStream.makeStream(of: Data.self)
        let errorPair = pty == nil ? AsyncStream.makeStream(of: Data.self) : nil
        let state = ChannelOpenState()
        let environment = pty?.environment ?? []
        let _: Bool = try await loop.perform { loop -> Bool? in
            guard let session = loop.session else { throw SSHError.notConnected }
            while true {
                switch state.stage {
                case .open:
                    let raw = "session".withCString {
                        libssh2_channel_open_ex(session, $0, 7, 2 * 1024 * 1024, 32_768, nil, 0)
                    }
                    guard let raw else {
                        if loop.lastErrorCode == LIBSSH2_ERROR_EAGAIN { return nil }
                        throw SSHError.channelFailed(detail: loop.lastErrorMessage())
                    }
                    state.raw = raw
                    state.stage = .environment(0)
                case let .environment(index):
                    guard let raw = state.raw else { throw SSHError.notConnected }
                    if index >= environment.count {
                        state.stage = pty == nil ? .start : .pty
                        continue
                    }
                    let (name, value) = environment[index]
                    let result = name.withCString { n in
                        value.withCString { v in libssh2_channel_setenv_ex(raw, n, UInt32(strlen(n)), v, UInt32(strlen(v))) }
                    }
                    if result == LIBSSH2_ERROR_EAGAIN { return nil }
                    // A rejected variable (not in AcceptEnv) is not an error.
                    if result != 0 { state.rejectedEnvironment.append(name) }
                    state.stage = .environment(index + 1)
                case .pty:
                    guard let raw = state.raw, let pty else { throw SSHError.notConnected }
                    let result = pty.terminalType.withCString { term in
                        libssh2_channel_request_pty_ex(raw, term, UInt32(strlen(term)), nil, 0,
                                                       Int32(pty.columns), Int32(pty.rows), 0, 0)
                    }
                    if result == LIBSSH2_ERROR_EAGAIN { return nil }
                    if result != 0 { throw SSHError.channelFailed(detail: "The server refused a terminal: \(loop.lastErrorMessage())") }
                    state.stage = .start
                case .start:
                    guard let raw = state.raw else { throw SSHError.notConnected }
                    let result: Int32
                    if let command {
                        result = "exec".withCString { request in
                            command.withCString { libssh2_channel_process_startup(raw, request, 4, $0, UInt32(strlen($0))) }
                        }
                    } else {
                        result = "shell".withCString { libssh2_channel_process_startup(raw, $0, 5, nil, 0) }
                    }
                    if result == LIBSSH2_ERROR_EAGAIN { return nil }
                    if result != 0 { throw SSHError.channelFailed(detail: loop.lastErrorMessage()) }
                    let core = ChannelCore(raw: raw, readsStandardError: pty == nil,
                                           output: outputContinuation, errorOutput: errorPair?.continuation)
                    loop.channels.append(core)
                    state.core = core
                    loop.signal()  // Data may already be waiting.
                    return true
                }
            }
        }
        guard let core = state.core else { throw SSHError.notConnected }
        return SSHChannel(loop: loop, core: core, output: output, errorOutput: errorPair?.stream)
    }

    // MARK: - Disconnecting

    /// Closes the connection. Open channels finish their output streams.
    public func disconnect() {
        loop.shutdown()
    }
}

// MARK: - Helpers

private final class ConnectState: @unchecked Sendable {
    enum Stage { case startTransport, waitTransport, handshake }
    var stage = Stage.startTransport
    let deadline: Date
    init(deadline: Date) { self.deadline = deadline }
}

private final class ChannelOpenState: @unchecked Sendable {
    enum Stage { case open, environment(Int), pty, start }
    var stage = Stage.open
    var raw: OpaquePointer?
    var core: ChannelCore?
    var rejectedEnvironment: [String] = []
}

private final class WeakLoop: @unchecked Sendable {
    weak var value: SSHSessionLoop?
    init(_ value: SSHSessionLoop) { self.value = value }
}
