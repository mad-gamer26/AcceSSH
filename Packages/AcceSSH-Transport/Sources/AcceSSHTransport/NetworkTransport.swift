import Foundation
import Network
import AcceSSHCore

/// The TCP byte stream under libssh2, implemented with Network.framework.
///
/// Network.framework (unlike BSD sockets) activates the cellular radio and VPN On Demand on
/// iOS and follows the system's path selection, which is why libssh2 is given custom
/// send/receive callbacks instead of a socket. Receive data is buffered here and consumed by
/// libssh2 on the session thread; sends are handed to `NWConnection` with backpressure.
final class NetworkTransport: @unchecked Sendable {
    enum State: Equatable {
        case idle, connecting, ready, failed(SSHError), closed
    }

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "AcceSSH.network")
    private let host: String
    private let port: Int
    private let lock = NSLock()
    // Guarded by `lock`.
    private var inbound: [UInt8] = []
    private var inboundStart = 0
    private var inFlightBytes = 0
    private var _state: State = .idle
    private var receivedEOF = false
    private var lastWaitingError: NWError?
    private var activityHandler: (@Sendable () -> Void)?

    static let maximumInFlightBytes = 1 << 20

    init(host: String, port: Int, addressFamily: AddressFamilyPreference, connectTimeout: TimeInterval) {
        self.host = host
        self.port = port
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = max(1, Int(connectTimeout.rounded()))
        let parameters = NWParameters(tls: nil, tcp: tcp)
        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            switch addressFamily {
            case .automatic: break
            case .ipv4Only: ip.version = .v4
            case .ipv6Only: ip.version = .v6
            }
        }
        let endpointPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) ?? 22
        connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: parameters)
    }

    var state: State {
        lock.lock(); defer { lock.unlock() }
        return _state
    }

    /// The most informative error for a connection that has not become ready yet.
    var pendingConnectError: SSHError? {
        lock.lock(); defer { lock.unlock() }
        return lastWaitingError.map { Self.translate($0, host: host, port: port) }
    }

    /// Starts connecting. `onActivity` is called (on any thread) whenever data, send
    /// completions or state changes might let libssh2 make progress.
    func start(onActivity: @escaping @Sendable () -> Void) {
        lock.lock()
        activityHandler = onActivity
        _state = .connecting
        lock.unlock()
        connection.stateUpdateHandler = { [weak self] newState in self?.handle(newState) }
        connection.start(queue: queue)
    }

    func cancel() {
        lock.lock()
        if case .failed = _state {} else { _state = .closed }
        lock.unlock()
        connection.cancel()
    }

    private func handle(_ newState: NWConnection.State) {
        lock.lock()
        switch newState {
        case .ready:
            _state = .ready
        case let .waiting(error):
            // A refusal is definitive; other waiting reasons (no route yet) may resolve
            // before the timeout, so Network.framework keeps trying.
            if case .posix(.ECONNREFUSED) = error {
                _state = .failed(.connectionRefused(host: host, port: port))
            } else if case .dns = error, connection.currentPath?.status == .satisfied {
                // The network works but the name does not resolve.
                _state = .failed(.hostNotFound(host: host))
            } else {
                lastWaitingError = error
            }
        case let .failed(error):
            _state = .failed(Self.translate(error, host: host, port: port))
        case .cancelled:
            if case .failed = _state {} else { _state = .closed }
        default:
            break
        }
        let handler = activityHandler
        lock.unlock()
        if case .ready = newState { receiveNext() }
        handler?()
    }

    private func receiveNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            self.lock.lock()
            if let data, !data.isEmpty {
                if self.inboundStart > 65_536, self.inboundStart * 2 > self.inbound.count {
                    self.inbound.removeFirst(self.inboundStart)
                    self.inboundStart = 0
                }
                self.inbound.append(contentsOf: data)
            }
            var keepReading = true
            if let error {
                if case .ready = self._state {
                    self._state = .failed(.connectionLost(detail: error.localizedDescription))
                }
                keepReading = false
            } else if isComplete {
                self.receivedEOF = true
                keepReading = false
            }
            let handler = self.activityHandler
            self.lock.unlock()
            handler?()
            if keepReading { self.receiveNext() }
        }
    }

    // MARK: - libssh2 callbacks (session thread)

    /// Copies buffered bytes for libssh2. Returns a byte count, 0 at end of stream, or a
    /// negative errno (`-EAGAIN` when no data is buffered yet).
    func receive(into buffer: UnsafeMutableRawPointer, length: Int) -> Int {
        lock.lock(); defer { lock.unlock() }
        let available = inbound.count - inboundStart
        if available > 0 {
            let count = min(available, length)
            inbound.withUnsafeBytes { source in
                buffer.copyMemory(from: source.baseAddress! + inboundStart, byteCount: count)
            }
            inboundStart += count
            if inboundStart == inbound.count {
                inbound.removeAll(keepingCapacity: true)
                inboundStart = 0
            }
            return count
        }
        if receivedEOF { return 0 }
        if case .failed = _state { return -Int(ECONNRESET) }
        if case .closed = _state { return -Int(ECONNRESET) }
        return -Int(EAGAIN)
    }

    /// Accepts bytes from libssh2 for sending. Returns the count accepted or a negative errno.
    func send(_ buffer: UnsafeRawPointer, length: Int) -> Int {
        lock.lock()
        guard case .ready = _state else {
            lock.unlock()
            return -Int(ECONNRESET)
        }
        if inFlightBytes >= Self.maximumInFlightBytes {
            lock.unlock()
            return -Int(EAGAIN)
        }
        let count = min(length, Self.maximumInFlightBytes - inFlightBytes)
        inFlightBytes += count
        lock.unlock()

        let data = Data(bytes: buffer, count: count)
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.lock.lock()
            self.inFlightBytes -= count
            if let error, case .ready = self._state {
                self._state = .failed(.connectionLost(detail: error.localizedDescription))
            }
            let handler = self.activityHandler
            self.lock.unlock()
            handler?()
        })
        return count
    }

    var hasEnded: Bool {
        lock.lock(); defer { lock.unlock() }
        return receivedEOF && inbound.count == inboundStart
    }

    static func translate(_ error: NWError, host: String, port: Int) -> SSHError {
        switch error {
        case let .posix(code):
            switch code {
            case .ECONNREFUSED: return .connectionRefused(host: host, port: port)
            case .ETIMEDOUT: return .connectionTimedOut(host: host, seconds: 0)
            case .ENETDOWN, .ENETUNREACH, .EHOSTUNREACH, .EHOSTDOWN, .ENOTCONN:
                return .networkUnavailable(detail: error.localizedDescription)
            default: return .connectionLost(detail: error.localizedDescription)
            }
        case .dns:
            return .hostNotFound(host: host)
        default:
            return .connectionLost(detail: error.localizedDescription)
        }
    }
}
