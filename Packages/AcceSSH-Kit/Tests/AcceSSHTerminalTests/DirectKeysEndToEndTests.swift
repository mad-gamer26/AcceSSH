#if os(macOS)
import Foundation
import Testing
@testable import AcceSSHTerminal
@testable import AcceSSHAccessibility
import AcceSSHCore

/// Direct-keys speech against a real interactive bash, keystroke by keystroke, the way the
/// app sends them: each key is written, the echo is fed to the emulator, and the scheduler is
/// flushed once output settles.
@Suite("Direct keys speech end to end", .serialized)
struct DirectKeysEndToEndTests {
    typealias Shell = ShellIntegrationEndToEndTests.PTYShell

    final class Harness {
        let shell: Shell
        var scheduler = OutputSpeechScheduler(settings: VoiceOverSettings())
        var clock = Date()

        init() throws {
            shell = try Shell(executable: "/bin/bash", arguments: ["--noprofile", "--norc", "-i"])
            scheduler.speaksAllTypedText = true
            settle()
            _ = flush()
        }

        /// Reads until output has been quiet for a moment, feeding each update to the scheduler.
        func settle() {
            var buffer = [UInt8](repeating: 0, count: 4096)
            var quietSince = Date()
            while Date().timeIntervalSince(quietSince) < 0.3 {
                var descriptor = pollfd(fd: shell.master, events: Int16(POLLIN), revents: 0)
                guard poll(&descriptor, 1, 50) > 0 else { continue }
                let count = read(shell.master, &buffer, buffer.count)
                if count <= 0 { break }
                clock = clock.addingTimeInterval(0.01)
                scheduler.ingest(shell.terminal.feed(buffer[0..<count]), at: clock)
                quietSince = Date()
            }
        }

        func flush() -> [String] {
            clock = clock.addingTimeInterval(2)
            return scheduler.flush(at: clock).map(\.text)
        }

        /// Types text (as the app's insertText does) and returns what would be spoken.
        func type(_ text: String) -> [String] {
            clock = clock.addingTimeInterval(0.05)
            scheduler.noteUserTyped(text, at: clock)
            shell.send(text)
            settle()
            return flush()
        }

        /// Sends a key sequence (as the app's arrow keys do) and returns what would be spoken.
        func key(_ bytes: String) -> [String] {
            shell.send(bytes)
            settle()
            return flush()
        }
    }

    @Test func spacesCharactersAndCursorMovementAreSpoken() throws {
        let harness = try Harness()
        defer { harness.shell.finish() }
        #expect(harness.type("l") == ["l"])
        #expect(harness.type("s") == ["s"])
        #expect(harness.type(" ") == ["space"])
        #expect(harness.type("x") == ["x"])
        // Left Arrow moves onto "x", then onto the space, then onto "s".
        #expect(harness.key("\u{1B}[D") == ["x"])
        #expect(harness.key("\u{1B}[D") == ["space"])
        #expect(harness.key("\u{1B}[D") == ["s"])
        // Right Arrow back onto the space; End goes past the text.
        #expect(harness.key("\u{1B}[C") == ["space"])
        #expect(harness.key("\u{1B}[F") == ["blank"])
        // Backspace deletes "x" and says so.
        #expect(harness.type("\u{7F}") == ["x"])
    }

    /// Typing faster than speech is flushed: the space must not be lost.
    @Test func fastTypingStillSpeaksSpaces() throws {
        let harness = try Harness()
        defer { harness.shell.finish() }
        #expect(harness.type("a ") == ["a space"])
        #expect(harness.type("b") == ["b"])
    }
}
#endif
