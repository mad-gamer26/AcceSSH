import Foundation
import CLibSSH2

/// One unit of libssh2 work, retried each time the session thread wakes until it finishes.
final class LoopOperation: @unchecked Sendable {
    /// Returns `true` when finished (successfully or not), `false` to retry after more I/O.
    let attempt: (SSHSessionLoop) -> Bool
    /// Called instead of `attempt` when the session ends before the operation could run.
    let abandon: (SSHError) -> Void

    init(attempt: @escaping (SSHSessionLoop) -> Bool, abandon: @escaping (SSHError) -> Void) {
        self.attempt = attempt
        self.abandon = abandon
    }
}

/// Signals that a libssh2 call would block; the operation is retried later.
struct WouldBlock: Error {}

/// Owns a libssh2 session and runs it on one dedicated thread.
///
/// libssh2 is not thread-safe, so every call into it happens on this thread. The session is
/// non-blocking: operations that return `LIBSSH2_ERROR_EAGAIN` are retried when the
/// transport reports activity. A dedicated thread (rather than the Swift cooperative pool)
/// is used because libssh2's keyboard-interactive callback is synchronous and must wait for
/// the person's answer; blocking this thread is harmless, blocking the pool is not.
final class SSHSessionLoop: @unchecked Sendable {
    let transport: NetworkTransport
    let host: String
    let port: Int
    let connectTimeout: TimeInterval
    let keepAliveInterval: TimeInterval?
    let useCompression: Bool

    // Guarded by `condition`.
    private let condition = NSCondition()
    private var submitted: [LoopOperation] = []
    private var isSignaled = false
    private var shutdownRequested = false
    private var terminalError: SSHError?
    private var isFinished = false

    // Session-thread state.
    private(set) var session: OpaquePointer?
    private var operations: [LoopOperation] = []
    var channels: [ChannelCore] = []
    var keyboardInteractive: KeyboardInteractiveContext?
    var isAuthenticated = false
    private var placeholderSockets: [Int32] = [-1, -1]
    private var nextKeepAlive = Date.distantFuture

    let events: AsyncStream<SSHConnectionEvent>
    private let eventContinuation: AsyncStream<SSHConnectionEvent>.Continuation

    private static let libraryInitialized: Bool = {
        libssh2_init(0) == 0
    }()

    init(host: String, port: Int, connectTimeout: TimeInterval, keepAliveInterval: TimeInterval?,
         useCompression: Bool, transport: NetworkTransport) {
        self.host = host
        self.port = port
        self.connectTimeout = connectTimeout
        self.keepAliveInterval = keepAliveInterval
        self.useCompression = useCompression
        self.transport = transport
        (events, eventContinuation) = AsyncStream.makeStream(of: SSHConnectionEvent.self)
        _ = Self.libraryInitialized
    }

    func start() {
        let thread = Thread { [self] in run() }
        thread.name = "AcceSSH session \(host)"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    // MARK: - Submitting work

    func signal() {
        condition.lock()
        isSignaled = true
        condition.signal()
        condition.unlock()
    }

    func submit(_ operation: LoopOperation) {
        condition.lock()
        if isFinished {
            let error = terminalError ?? .notConnected
            condition.unlock()
            operation.abandon(error)
            return
        }
        submitted.append(operation)
        isSignaled = true
        condition.signal()
        condition.unlock()
    }

    /// Runs `body` on the session thread until it returns a value or throws. Throwing
    /// ``WouldBlock`` (or returning `nil`) retries after more I/O.
    func perform<T: Sendable>(_ body: @escaping (SSHSessionLoop) throws -> T?) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            submit(LoopOperation(
                attempt: { loop in
                    do {
                        guard let value = try body(loop) else { return false }
                        continuation.resume(returning: value)
                    } catch is WouldBlock {
                        return false
                    } catch {
                        continuation.resume(throwing: error)
                    }
                    return true
                },
                abandon: { continuation.resume(throwing: $0) }
            ))
        }
    }

    /// Ends the session: pending work fails with `.cancelled`.
    func shutdown() {
        condition.lock()
        shutdownRequested = true
        isSignaled = true
        condition.signal()
        condition.unlock()
    }

    // MARK: - The loop

    private func run() {
        while true {
            condition.lock()
            let deadline = Date().addingTimeInterval(0.5)
            while !isSignaled && !shutdownRequested {
                if !condition.wait(until: deadline) { break }
            }
            isSignaled = false
            operations.append(contentsOf: submitted)
            submitted.removeAll()
            let stop = shutdownRequested
            condition.unlock()

            if stop {
                gracefulDisconnect()
                finish(with: .cancelled)
                return
            }
            runOperations()
            pumpChannels()
            if let fatal = checkConnectionHealth() {
                finish(with: fatal)
                return
            }
        }
    }

    private func runOperations() {
        while let operation = operations.first {
            if operation.attempt(self) {
                operations.removeFirst()
            } else {
                break
            }
        }
    }

    private func checkConnectionHealth() -> SSHError? {
        guard session != nil else { return nil }
        if case let .failed(error) = transport.state {
            return error
        }
        if transport.hasEnded {
            return .connectionLost(detail: "The server closed the connection.")
        }
        if isAuthenticated, keepAliveInterval != nil, Date() >= nextKeepAlive, let session {
            var seconds: Int32 = 0
            let result = libssh2_keepalive_send(session, &seconds)
            if result != 0, result != LIBSSH2_ERROR_EAGAIN {
                return .connectionLost(detail: lastErrorMessage())
            }
            nextKeepAlive = Date().addingTimeInterval(TimeInterval(max(seconds, 1)))
        }
        return nil
    }

    private func gracefulDisconnect() {
        guard let session else { return }
        // Best effort, bounded: the server may already be gone.
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline {
            let result = libssh2_session_disconnect_ex(session, SSH_DISCONNECT_BY_APPLICATION, "Closed by AcceSSH", "")
            if result != LIBSSH2_ERROR_EAGAIN { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    private func finish(with error: SSHError) {
        condition.lock()
        isFinished = true
        terminalError = error
        let pending = submitted
        submitted.removeAll()
        condition.unlock()

        for operation in operations + pending { operation.abandon(error) }
        operations.removeAll()
        for channel in channels { channel.finish(error: error == .cancelled ? nil : error) }
        channels.removeAll()
        if let session {
            libssh2_session_free(session)
            self.session = nil
        }
        for fd in placeholderSockets where fd >= 0 { close(fd) }
        placeholderSockets = [-1, -1]
        transport.cancel()
        eventContinuation.yield(.disconnected(error == .cancelled ? nil : error))
        eventContinuation.finish()
    }

    // MARK: - Session setup (session thread)

    /// Creates the libssh2 session wired to the Network.framework transport.
    func createSession() throws {
        let abstract = Unmanaged.passUnretained(self).toOpaque()
        guard let session = libssh2_session_init_ex(nil, nil, nil, abstract) else {
            throw SSHError.handshakeFailed(detail: "libssh2 could not allocate a session.")
        }
        self.session = session
        libssh2_session_set_blocking(session, 0)
        _ = libssh2_session_callback_set2(session, LIBSSH2_CALLBACK_SEND, unsafeBitCast(sshSendCallback, to: (@convention(c) () -> Void).self))
        _ = libssh2_session_callback_set2(session, LIBSSH2_CALLBACK_RECV, unsafeBitCast(sshReceiveCallback, to: (@convention(c) () -> Void).self))
        _ = libssh2_session_banner_set(session, "SSH-2.0-AcceSSH_1.0")
        if useCompression { _ = libssh2_session_flag(session, LIBSSH2_FLAG_COMPRESS, 1) }
        // The handshake insists on a real descriptor to toggle non-blocking mode; all bytes
        // actually flow through the callbacks above.
        var fds: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
            throw SSHError.handshakeFailed(detail: "Could not create the placeholder socket.")
        }
        placeholderSockets = fds
        _ = fcntl(fds[0], F_SETFL, O_NONBLOCK)
    }

    var placeholderSocket: Int32 { placeholderSockets[0] }

    func didAuthenticate() {
        isAuthenticated = true
        if let session, let interval = keepAliveInterval {
            libssh2_keepalive_config(session, 1, UInt32(max(1, interval)))
            nextKeepAlive = Date().addingTimeInterval(interval)
        }
    }

    func emit(_ event: SSHConnectionEvent) {
        eventContinuation.yield(event)
    }

    // MARK: - Errors

    func lastErrorMessage() -> String {
        guard let session else { return "No session." }
        var message: UnsafeMutablePointer<CChar>?
        var length: Int32 = 0
        _ = libssh2_session_last_error(session, &message, &length, 0)
        guard let message else { return "Unknown error." }
        return String(cString: message)
    }

    var lastErrorCode: Int32 {
        guard let session else { return 0 }
        return libssh2_session_last_errno(session)
    }

    /// Throws ``WouldBlock`` for EAGAIN, otherwise an `SSHError` for a negative result code.
    func check(_ result: Int32, _ makeError: (Int32, String) -> SSHError) throws {
        if result == LIBSSH2_ERROR_EAGAIN { throw WouldBlock() }
        if result < 0 { throw makeError(result, lastErrorMessage()) }
    }

    // MARK: - Channels

    private func pumpChannels() {
        guard !channels.isEmpty else { return }
        for channel in channels { channel.pump(self) }
        channels.removeAll { $0.isFreed }
    }
}

// MARK: - C callbacks

private func loop(from abstract: UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> SSHSessionLoop? {
    guard let pointer = abstract?.pointee else { return nil }
    return Unmanaged<SSHSessionLoop>.fromOpaque(pointer).takeUnretainedValue()
}

private let sshSendCallback: @convention(c) (libssh2_socket_t, UnsafeRawPointer?, Int, Int32, UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> Int = { _, buffer, length, _, abstract in
    guard let loop = loop(from: abstract), let buffer else { return -Int(EBADF) }
    return loop.transport.send(buffer, length: length)
}

private let sshReceiveCallback: @convention(c) (libssh2_socket_t, UnsafeMutableRawPointer?, Int, Int32, UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> Int = { _, buffer, length, _, abstract in
    guard let loop = loop(from: abstract), let buffer else { return -Int(EBADF) }
    return loop.transport.receive(into: buffer, length: length)
}

/// State for an in-progress keyboard-interactive exchange.
final class KeyboardInteractiveContext: @unchecked Sendable {
    let responder: SSHKeyboardInteractiveResponder
    var wasCancelled = false
    var rounds = 0

    init(responder: @escaping SSHKeyboardInteractiveResponder) {
        self.responder = responder
    }
}

let keyboardInteractiveCallback: @convention(c) (
    UnsafePointer<CChar>?, Int32, UnsafePointer<CChar>?, Int32, Int32,
    UnsafePointer<LIBSSH2_USERAUTH_KBDINT_PROMPT>?, UnsafeMutablePointer<LIBSSH2_USERAUTH_KBDINT_RESPONSE>?,
    UnsafeMutablePointer<UnsafeMutableRawPointer?>?
) -> Void = { name, nameLength, instruction, instructionLength, promptCount, prompts, responses, abstract in
    guard let loop = loop(from: abstract), let context = loop.keyboardInteractive else { return }
    context.rounds += 1

    func string(_ pointer: UnsafePointer<CChar>?, _ length: Int32) -> String {
        guard let pointer, length > 0 else { return "" }
        return pointer.withMemoryRebound(to: UInt8.self, capacity: Int(length)) {
            String(decoding: UnsafeBufferPointer(start: $0, count: Int(length)), as: UTF8.self)
        }
    }
    var challengePrompts: [SSHKeyboardInteractiveChallenge.Prompt] = []
    for index in 0..<Int(max(promptCount, 0)) {
        guard let prompt = prompts?[index] else { continue }
        let text = prompt.text.map { String(decoding: UnsafeBufferPointer(start: $0, count: prompt.length), as: UTF8.self) } ?? ""
        challengePrompts.append(.init(text: text, echo: prompt.echo != 0))
    }
    let challenge = SSHKeyboardInteractiveChallenge(
        name: string(name, nameLength), instruction: string(instruction, instructionLength), prompts: challengePrompts
    )

    // Servers may send an empty round (no prompts) that just expects an empty reply.
    var answers: [String]? = []
    if !challengePrompts.isEmpty {
        let semaphore = DispatchSemaphore(value: 0)
        let box = AnswerBox()
        let responder = context.responder
        Task.detached {
            box.answers = await responder(challenge)
            semaphore.signal()
        }
        semaphore.wait()
        answers = box.answers
    }
    guard let answers else {
        context.wasCancelled = true
        return
    }
    for index in 0..<min(Int(promptCount), answers.count) {
        let bytes = Array(answers[index].utf8)
        // libssh2 frees responses with its default allocator (free), so allocate with malloc.
        guard let memory = malloc(max(bytes.count, 1))?.assumingMemoryBound(to: CChar.self) else { continue }
        bytes.withUnsafeBytes { source in
            if let base = source.baseAddress { memcpy(memory, base, bytes.count) }
        }
        responses?[index].text = memory
        responses?[index].length = UInt32(bytes.count)
    }
}

private final class AnswerBox: @unchecked Sendable {
    var answers: [String]?
}
