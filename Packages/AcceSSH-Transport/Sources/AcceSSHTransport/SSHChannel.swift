import Foundation
import CLibSSH2

/// Session-thread state for one libssh2 channel.
final class ChannelCore: @unchecked Sendable {
    private enum Stage { case open, closing, waitingClosed, freeing, freed }

    let raw: OpaquePointer
    let readsStandardError: Bool
    private let output: AsyncStream<Data>.Continuation
    private let errorOutput: AsyncStream<Data>.Continuation?
    private var stage = Stage.open
    private(set) var exitStatus: Int32?
    private var exitWaiters: [CheckedContinuation<Int32?, Never>] = []
    private var finished = false
    private static let readSize = 32_768
    private static let maximumBytesPerPump = 1 << 20

    init(raw: OpaquePointer, readsStandardError: Bool,
         output: AsyncStream<Data>.Continuation, errorOutput: AsyncStream<Data>.Continuation?) {
        self.raw = raw
        self.readsStandardError = readsStandardError
        self.output = output
        self.errorOutput = errorOutput
    }

    var isFreed: Bool { stage == .freed }
    var isOpen: Bool { stage == .open }

    /// Reads available data and advances the close sequence. Session thread only.
    func pump(_ loop: SSHSessionLoop) {
        var buffer = [UInt8](repeating: 0, count: Self.readSize)
        while true {
            switch stage {
            case .open:
                var total = 0
                for stream in readsStandardError ? [Int32(0), 1] : [0] {
                    while total < Self.maximumBytesPerPump {
                        let count = buffer.withUnsafeMutableBytes { pointer in
                            libssh2_channel_read_ex(raw, stream, pointer.baseAddress!.assumingMemoryBound(to: CChar.self), Self.readSize)
                        }
                        if count > 0 {
                            total += count
                            let data = Data(buffer[0..<count])
                            if stream == 0 { output.yield(data) } else { errorOutput?.yield(data) }
                        } else {
                            if count < 0, count != Int(LIBSSH2_ERROR_EAGAIN) {
                                stage = .closing
                            }
                            break
                        }
                    }
                }
                if total >= Self.maximumBytesPerPump { loop.signal() }  // More may be waiting.
                if stage == .open, libssh2_channel_eof(raw) != 0 { stage = .closing }
                if stage == .open { return }
            case .closing:
                let result = libssh2_channel_close(raw)
                if result == LIBSSH2_ERROR_EAGAIN { return }
                stage = .waitingClosed
            case .waitingClosed:
                let result = libssh2_channel_wait_closed(raw)
                if result == LIBSSH2_ERROR_EAGAIN { return }
                exitStatus = libssh2_channel_get_exit_status(raw)
                stage = .freeing
            case .freeing:
                let result = libssh2_channel_free(raw)
                if result == LIBSSH2_ERROR_EAGAIN { return }
                stage = .freed
                finish(error: nil)
                return
            case .freed:
                return
            }
        }
    }

    /// Starts an orderly close (from `SSHChannel.close()`).
    func requestClose() {
        if stage == .open { stage = .closing }
    }

    func finish(error: SSHError?) {
        guard !finished else { return }
        finished = true
        output.finish()
        errorOutput?.finish()
        let waiters = exitWaiters
        exitWaiters.removeAll()
        for waiter in waiters { waiter.resume(returning: exitStatus) }
    }

    func addExitWaiter(_ continuation: CheckedContinuation<Int32?, Never>) {
        if finished { continuation.resume(returning: exitStatus) } else { exitWaiters.append(continuation) }
    }
}

/// An open SSH channel: an interactive shell or a command.
public final class SSHChannel: Sendable {
    private let loop: SSHSessionLoop
    private let core: ChannelCore

    /// Bytes from the remote side (stdout; for a PTY this includes stderr). Single consumer.
    public let output: AsyncStream<Data>
    /// Standard error for commands run without a PTY.
    public let errorOutput: AsyncStream<Data>?

    init(loop: SSHSessionLoop, core: ChannelCore, output: AsyncStream<Data>, errorOutput: AsyncStream<Data>?) {
        self.loop = loop
        self.core = core
        self.output = output
        self.errorOutput = errorOutput
    }

    /// Sends bytes (keystrokes or pasted text). Completes when libssh2 has accepted all of them.
    public func write(_ data: Data) async throws {
        guard !data.isEmpty else { return }
        let bytes = [UInt8](data)
        let progress = WriteProgress()
        let core = self.core
        let _: Bool = try await loop.perform { loop in
            guard core.isOpen else { throw SSHError.notConnected }
            while progress.offset < bytes.count {
                let written = bytes.withUnsafeBytes { pointer in
                    libssh2_channel_write_ex(core.raw, 0,
                                             pointer.baseAddress!.advanced(by: progress.offset).assumingMemoryBound(to: CChar.self),
                                             bytes.count - progress.offset)
                }
                if written == Int(LIBSSH2_ERROR_EAGAIN) { return nil }
                if written < 0 { throw SSHError.connectionLost(detail: loop.lastErrorMessage()) }
                progress.offset += written
            }
            return true
        }
    }

    public func write(_ bytes: [UInt8]) async throws {
        try await write(Data(bytes))
    }

    /// Tells the server the terminal size changed (SIGWINCH on the remote side).
    public func resize(columns: Int, rows: Int) async throws {
        let core = self.core
        let _: Bool = try await loop.perform { loop in
            guard core.isOpen else { return true }
            let result = libssh2_channel_request_pty_size_ex(core.raw, Int32(columns), Int32(rows), 0, 0)
            try loop.check(result) { _, message in .channelFailed(detail: message) }
            return true
        }
    }

    /// Sends end-of-file (closes the remote program's standard input).
    public func sendEOF() async throws {
        let core = self.core
        let _: Bool = try await loop.perform { loop in
            guard core.isOpen else { return true }
            try loop.check(libssh2_channel_send_eof(core.raw)) { _, message in .channelFailed(detail: message) }
            return true
        }
    }

    /// Closes the channel. Output finishes once the server confirms.
    public func close() async {
        let core = self.core
        _ = try? await loop.perform { loop -> Bool? in
            core.requestClose()
            loop.signal()
            return true
        }
    }

    /// The remote program's exit status once the channel closes (`nil` if not reported).
    public func exitStatus() async -> Int32? {
        let core = self.core
        let loop = self.loop
        return await withCheckedContinuation { continuation in
            loop.submit(LoopOperation(
                attempt: { _ in core.addExitWaiter(continuation); return true },
                abandon: { _ in continuation.resume(returning: core.exitStatus) }
            ))
        }
    }
}

private final class WriteProgress: @unchecked Sendable {
    var offset = 0
}
