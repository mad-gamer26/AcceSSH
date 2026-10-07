import Foundation
import Testing
@testable import AcceSSHTerminal
import AcceSSHShellIntegration

@Suite("Semantic model")
struct SemanticTests {
    let A = "\u{1B}]133;A\u{07}"
    let B = "\u{1B}]133;B\u{07}"
    let C = "\u{1B}]133;C\u{07}"
    func D(_ status: Int) -> String { "\u{1B}]133;D;\(status)\u{07}" }

    @Test func osc133MarksDelimitCommandsAndOutput() throws {
        let terminal = TerminalEmulator(columns: 40, rows: 10)
        terminal.feed("\(A)$ \(B)ls\r\n\(C)file1\r\nfile2\r\n\(D(0))\(A)$ \(B)")
        let commands = terminal.commands
        #expect(commands.count == 2)
        let first = commands[0]
        #expect(first.commandLine == "ls")
        #expect(!first.isCommandLineReported)
        #expect(first.exitStatus == 0)
        #expect(first.phase == .finished)
        #expect(terminal.outputText(of: first) == "file1\nfile2")
        #expect(terminal.shellIntegrationState.status == .marksOnly)
        #expect(commands[1].phase == .input)
    }

    @Test func acceSSHHandshakeAndReportedCommandLine() throws {
        let terminal = TerminalEmulator(columns: 40, rows: 10)
        terminal.expectedIntegrationToken = "secret-token"
        let hello = "\u{1B}]6973;hello;v=1;shell=zsh;sv=1.0.0;caps=prompt,command,exit,cwd;token=secret-token\u{07}"
        let update = terminal.feed("\(hello)\u{1B}]6973;cwd;path=/home/m%3Bx\u{07}\(A)% \(B)false\r\n\u{1B}]6973;command;cmd=false\u{07}\(C)\(D(1))")
        let state = terminal.shellIntegrationState
        #expect(state.status == .active)
        #expect(state.isTokenVerified)
        #expect(state.shell == "zsh")
        #expect(state.capabilities.contains(.workingDirectory))
        #expect(terminal.workingDirectory == "/home/m;x")
        let command = try #require(terminal.commands.first)
        #expect(command.commandLine == "false")
        #expect(command.isCommandLineReported)
        #expect(command.exitStatus == 1)
        #expect(command.workingDirectory == "/home/m;x")
        #expect(update.events.contains { if case .commandFinished = $0 { true } else { false } })
    }

    @Test func wrongTokenIsNotVerified() {
        let terminal = TerminalEmulator()
        terminal.expectedIntegrationToken = "expected"
        terminal.feed("\u{1B}]6973;hello;v=1;token=forged\u{07}")
        #expect(terminal.shellIntegrationState.status == .active)
        #expect(!terminal.shellIntegrationState.isTokenVerified)
    }

    @Test func newerProtocolStillWorks() {
        let terminal = TerminalEmulator()
        terminal.feed("\u{1B}]6973;hello;v=9;shell=bash\u{07}\u{1B}]6973;future-event;x=1\u{07}")
        #expect(terminal.shellIntegrationState.status == .newerProtocol)
    }

    @Test func promptRedrawDoesNotCreateDuplicateRecords() {
        let terminal = TerminalEmulator(columns: 40, rows: 5)
        terminal.feed("\(A)$ \(B)\r\(A)$ \(B)")
        #expect(terminal.commands.count == 1)
    }

    @Test func committedLinesCarrySemanticKinds() {
        let terminal = TerminalEmulator(columns: 40, rows: 10)
        terminal.feed("\(A)$ \(B)")
        let update = terminal.feed("echo hi\r\n\(C)hi\r\n\(D(0))\(A)$ \(B)")
        #expect(update.committedLines.map(\.kind) == [.prompt, .output])
        #expect(update.committedLines.last?.text == "hi")
        #expect(update.cursorLineText == "$")
    }

    @Test func disabledIntegrationIgnoresMarks() {
        let terminal = TerminalEmulator()
        terminal.isShellIntegrationDisabled = true
        terminal.feed("\(A)$ \(B)ls\r\n\(C)\(D(0))")
        #expect(terminal.commands.isEmpty)
        #expect(terminal.shellIntegrationState.status == .disabled)
    }

    @Test func heuristicPromptsGroupOutputWithoutIntegration() throws {
        let terminal = TerminalEmulator(columns: 40, rows: 10)
        terminal.feed("user@host:~$ ")
        #expect(terminal.recordHeuristicPrompt())
        terminal.feed("ls")
        terminal.noteHeuristicCommandSubmitted(commandLine: "ls")
        terminal.feed("\r\na.txt\r\nb.txt\r\nuser@host:~$ ")
        #expect(terminal.recordHeuristicPrompt())
        let first = try #require(terminal.commands.first)
        #expect(first.source == .heuristic)
        #expect(first.commandLine == "ls")
        #expect(terminal.outputText(of: first) == "a.txt\nb.txt")
        #expect(first.exitStatus == nil)
    }

    @Test func heuristicsAreIgnoredWhenIntegrationIsActive() {
        let terminal = TerminalEmulator()
        terminal.feed("\(A)$ \(B)")
        #expect(!terminal.recordHeuristicPrompt())
        #expect(terminal.commands.allSatisfy { $0.source == .shellIntegration })
    }

    @Test func vsCodeIntegrationIsUnderstood() throws {
        let terminal = TerminalEmulator(columns: 40, rows: 5)
        terminal.feed("\u{1B}]633;A\u{07}$ \u{1B}]633;B\u{07}echo a\\x3bb\r\n\u{1B}]633;E;echo a\\x3bb;nonce\u{07}\u{1B}]633;C\u{07}a\r\nb\r\n\u{1B}]633;D;0\u{07}")
        let command = try #require(terminal.commands.first)
        #expect(command.commandLine == "echo a;b")
        #expect(command.exitStatus == 0)
    }
}
