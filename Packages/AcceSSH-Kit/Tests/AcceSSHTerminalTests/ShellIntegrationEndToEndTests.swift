#if os(macOS)
import Foundation
import Testing
@testable import AcceSSHTerminal
import AcceSSHShellIntegration

/// Runs the real bash and zsh integration scripts in a pseudo-terminal and feeds their
/// output through the emulator, verifying the whole path from shell hooks to semantic model.
@Suite("Shell integration end to end", .serialized)
struct ShellIntegrationEndToEndTests {
    /// A shell running on a PTY whose output drives a ``TerminalEmulator``.
    final class PTYShell {
        let process = Process()
        let master: Int32
        let terminal = TerminalEmulator(columns: 100, rows: 40)
        let home: URL

        init(executable: String, arguments: [String]) throws {
            var masterFD: Int32 = -1, slaveFD: Int32 = -1
            var size = winsize(ws_row: 40, ws_col: 100, ws_xpixel: 0, ws_ypixel: 0)
            guard openpty(&masterFD, &slaveFD, nil, nil, &size) == 0 else { throw POSIXError(.EIO) }
            master = masterFD
            home = FileManager.default.temporaryDirectory.appendingPathComponent("accessh-test-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

            let slave = FileHandle(fileDescriptor: slaveFD, closeOnDealloc: true)
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardInput = slave
            process.standardOutput = slave
            process.standardError = slave
            process.environment = [
                "TERM": "xterm-256color", "HOME": home.path, "PATH": "/usr/bin:/bin",
                "HISTFILE": home.appendingPathComponent("history").path, "LC_ACCESSH_TOKEN": "t0k",
                "PS1": "test$ ", "PROMPT": "test% ", "USER": "tester",
            ]
            try process.run()
            try? slave.close()
        }

        deinit {
            if process.isRunning { process.terminate() }
            close(master)
            try? FileManager.default.removeItem(at: home)
        }

        func send(_ text: String) {
            let bytes = Array(text.utf8)
            _ = bytes.withUnsafeBytes { write(master, $0.baseAddress, $0.count) }
        }

        /// Reads output into the emulator until `condition` holds or the timeout passes.
        @discardableResult
        func read(until condition: (TerminalEmulator) -> Bool, timeout: TimeInterval = 10) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            var buffer = [UInt8](repeating: 0, count: 4096)
            while Date() < deadline {
                if condition(terminal) { return true }
                var descriptor = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
                guard poll(&descriptor, 1, 100) > 0 else { continue }
                let count = Foundation.read(master, &buffer, buffer.count)
                if count <= 0 { break }
                let update = terminal.feed(buffer[0..<count])
                if !update.responses.isEmpty { _ = update.responses.withUnsafeBytes { write(master, $0.baseAddress, $0.count) } }
            }
            return condition(terminal)
        }

        /// Asks the shell to exit, then terminates it if it has not exited within a few seconds.
        func finish() {
            send("exit\n")
            let deadline = Date().addingTimeInterval(3)
            while process.isRunning && Date() < deadline {
                read(until: { _ in false }, timeout: 0.1)
            }
            if process.isRunning { process.terminate() }
        }

        func waitForPrompt(count: Int) -> Bool {
            read { terminal in terminal.commands.count >= count && terminal.commands.last?.phase == .input }
        }
    }

    func scriptPath(_ shell: ShellKind) throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("accessh-\(UUID().uuidString).\(shell.rawValue)")
        try ShellIntegrationScripts.script(for: shell).write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    func exercise(_ shell: PTYShell, scriptPath: String, expectedShell: String) throws {
        // Let the shell start, then load the integration as "Activate on connect" would.
        shell.read(until: { _ in false }, timeout: 0.5)
        shell.send(" . \(scriptPath)\n")
        #expect(shell.waitForPrompt(count: 1), "integration did not produce a prompt mark")

        let state = shell.terminal.shellIntegrationState
        #expect(state.status == .active)
        #expect(state.shell == expectedShell)
        #expect(state.isTokenVerified == false)  // no expected token configured on this emulator

        shell.send("echo accessh-ok\n")
        #expect(shell.waitForPrompt(count: 2))
        shell.send("ls /nonexistent-accessh-path\n")
        #expect(shell.waitForPrompt(count: 3))
        shell.send("cd /tmp\n")
        #expect(shell.waitForPrompt(count: 4))

        let commands = shell.terminal.commands.filter(\.didExecute)
        #expect(commands.count == 3, "Screen:\n\(shell.terminal.fullText())")
        guard commands.count == 3 else { return }
        #expect(commands[0].commandLine == "echo accessh-ok")
        #expect(commands[0].exitStatus == 0)
        #expect(shell.terminal.outputText(of: commands[0]) == "accessh-ok")
        #expect(commands[1].commandLine == "ls /nonexistent-accessh-path")
        #expect((commands[1].exitStatus ?? 0) != 0)
        #expect(shell.terminal.outputText(of: commands[1])?.contains("No such file") == true)
        #expect(shell.terminal.workingDirectory?.hasSuffix("/tmp") == true)

        shell.finish()
    }

    @Test func bashIntegration() throws {
        let path = try scriptPath(.bash)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let shell = try PTYShell(executable: "/bin/bash", arguments: ["--noprofile", "--norc", "-i"])
        try exercise(shell, scriptPath: path, expectedShell: "bash")
    }

    @Test func zshIntegration() throws {
        let path = try scriptPath(.zsh)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let shell = try PTYShell(executable: "/bin/zsh", arguments: ["-f", "-i"])
        try exercise(shell, scriptPath: path, expectedShell: "zsh")
    }

    @Test func bashHiddenCommandsAreNotReported() throws {
        let path = try scriptPath(.bash)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let shell = try PTYShell(executable: "/bin/bash", arguments: ["--noprofile", "--norc", "-i"])
        shell.read(until: { _ in false }, timeout: 0.5)
        shell.send("HISTCONTROL=ignorespace; . \(path)\n")
        #expect(shell.waitForPrompt(count: 1))
        shell.send(" echo secret-value\n")
        #expect(shell.waitForPrompt(count: 2))
        let command = shell.terminal.commands.first(where: \.didExecute)
        // The command text is extracted from the screen (what the person can already see),
        // but it is not marked as reported by the shell.
        #expect(command?.isCommandLineReported == false)
        shell.finish()
    }
}
#endif
