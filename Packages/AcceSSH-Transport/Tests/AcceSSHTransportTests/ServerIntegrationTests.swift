import Foundation
import Testing
@testable import AcceSSHTransport
import AcceSSHTerminal
import AcceSSHAccessibility
import AcceSSHCore
import AcceSSHShellIntegration

/// Shell integration installed on the live test server, exercised through the same path the
/// app uses: libssh2 shell with LC_TERMINAL and a session token, the emulator, and the speech
/// scheduler. Enabled with ACCESSH_TEST_EXPECT_INTEGRATION=1.
/// Collects channel output for the test to drain.
actor ChunkBuffer {
    private var chunks: [Data] = []
    func append(_ chunk: Data) { chunks.append(chunk) }
    func take() -> [Data] {
        defer { chunks.removeAll() }
        return chunks
    }
}

@Suite("Shell integration on the live server",
       .enabled(if: LiveServer.isConfigured && ProcessInfo.processInfo.environment["ACCESSH_TEST_EXPECT_INTEGRATION"] == "1"))
struct ServerIntegrationTests {
    final class Session {
        let terminal = TerminalEmulator(columns: 100, rows: 30)
        var scheduler = OutputSpeechScheduler(settings: VoiceOverSettings())
        let shell: SSHChannel
        let connection: SSHConnection
        var spoken: [String] = []
        var events: [TerminalEvent] = []
        let token = UUID().uuidString
        let buffer = ChunkBuffer()

        init() async throws {
            connection = try await LiveServer.connectAndAuthenticate()
            shell = try await connection.openShell(SSHShellRequest(columns: 100, rows: 30, environment: [
                ("LC_TERMINAL", AcceSSHProduct.terminalEnvironmentValue),
                (AcceSSHProduct.integrationTokenEnvironmentKey, token),
            ]))
            terminal.expectedIntegrationToken = token
            let output = shell.output
            let buffer = self.buffer
            Task {
                for await chunk in output { await buffer.append(chunk) }
            }
        }

        /// Reads output until `condition` holds, feeding the emulator and scheduler.
        func read(until condition: (TerminalEmulator) -> Bool, timeout: TimeInterval = 15) async -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                for chunk in await buffer.take() {
                    let update = terminal.feed(chunk)
                    events += update.events
                    scheduler.ingest(update, at: Date())
                }
                if condition(terminal) { return true }
                try? await Task.sleep(for: .milliseconds(50))
            }
            return condition(terminal)
        }

        func run(_ command: String, expectingCommands count: Int) async -> Bool {
            scheduler.noteUserSubmitted(at: Date())
            try? await shell.write(Data((command + "\r").utf8))
            let done = await read { terminal in
                terminal.commands.filter { $0.phase == .finished }.count >= count && terminal.currentCommand?.phase == .input
            }
            spoken += scheduler.flush(at: Date().addingTimeInterval(5), force: true).map(\.text)
            return done
        }
    }

    @Test func commandsExitStatusesOutputAndSpeech() async throws {
        let session = try await Session()
        defer { session.connection.disconnect() }
        #expect(await session.read { $0.shellIntegrationState.status == .active && $0.currentCommand?.phase == .input })

        let state = session.terminal.shellIntegrationState
        #expect(state.shell == "bash")
        #expect(state.isTokenVerified, "The hello must echo the token AcceSSH sent")
        #expect(state.scriptVersion == ShellIntegrationScripts.scriptVersion)

        #expect(await session.run("echo \"Hello, World!\"", expectingCommands: 1))
        #expect(await session.run("ls /no-such-accessh-path", expectingCommands: 2))
        #expect(await session.run("cd /tmp", expectingCommands: 3))

        let finished = session.terminal.commands.filter { $0.phase == .finished }
        guard finished.count >= 3 else { Issue.record("Only \(finished.count) commands finished"); return }
        #expect(finished[0].commandLine == "echo \"Hello, World!\"")
        #expect(finished[0].isCommandLineReported)
        #expect(finished[0].exitStatus == 0)
        #expect(session.terminal.outputText(of: finished[0]) == "Hello, World!")
        #expect(finished[1].exitStatus == 2)
        #expect(session.terminal.outputText(of: finished[1])?.contains("No such file") == true)
        #expect(session.terminal.workingDirectory == "/tmp")

        // What AcceSSH would say: the output, and a failure announcement for ls.
        #expect(session.spoken.contains { $0.hasPrefix("Hello, World!") })
        let failure = AnnouncementComposer.commandFinished(finished[1], settings: VoiceOverSettings())
        #expect(failure?.text == "Command failed with exit status 2.")
        #expect(SemanticNavigator.lastCommandOutput(in: session.terminal) == "The last command produced no output.")
        #expect(SemanticNavigator.lastCommandDescription(in: session.terminal) == "cd /tmp. Succeeded.")
        print("SPOKEN:", session.spoken)
    }
}
