import Foundation
import Testing
@testable import AcceSSHAccessibility
import AcceSSHTerminal
import AcceSSHCore

@Suite("Output speech scheduling")
struct SpeechSchedulerTests {
    let start = Date(timeIntervalSinceReferenceDate: 1_000)
    let A = "\u{1B}]133;A\u{07}", B = "\u{1B}]133;B\u{07}", C = "\u{1B}]133;C\u{07}"

    func after(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    @Test func coalescesUntilQuietThenSpeaksLinesAndPrompt() {
        let terminal = TerminalEmulator(columns: 40, rows: 10)
        var scheduler = OutputSpeechScheduler(settings: VoiceOverSettings())
        scheduler.ingest(terminal.feed("\(A)$ \(B)"), at: start)
        _ = scheduler.flush(at: after(1))

        scheduler.noteUserTyped("ls", at: after(2))
        scheduler.ingest(terminal.feed("ls"), at: after(2))
        scheduler.noteUserSubmitted(at: after(2.1))
        scheduler.ingest(terminal.feed("\r\n\(C)alpha\r\n"), at: after(2.15))
        #expect(scheduler.flush(at: after(2.2)).isEmpty, "not quiet yet")
        scheduler.ingest(terminal.feed("beta\r\n\u{1B}]133;D;0\u{07}\(A)$ \(B)"), at: after(2.25))

        let spoken = scheduler.flush(at: after(3))
        #expect(spoken.map(\.text) == ["alpha\nbeta", "$"])
        #expect(spoken.map(\.kind) == [.output, .prompt])
    }

    /// The reported case: output and the next prompt arrive together without shell integration.
    @Test func outputIsSpokenBeforeTheNextPrompt() {
        let terminal = TerminalEmulator(columns: 60, rows: 10)
        for directKeys in [false, true] {
            var scheduler = OutputSpeechScheduler(settings: VoiceOverSettings())
            scheduler.speaksAllTypedText = directKeys
            scheduler.ingest(terminal.feed("\r\nmatthew@ubuntu:~$ "), at: start)
            _ = scheduler.flush(at: after(1))
            if directKeys {
                scheduler.noteUserTyped("echo \"Hello, World!\"", at: after(2))
                scheduler.ingest(terminal.feed("echo \"Hello, World!\""), at: after(2.01))
                _ = scheduler.flush(at: after(3))
            }
            scheduler.noteUserSubmitted(at: after(4))
            let update = terminal.feed((directKeys ? "" : "echo \"Hello, World!\"") + "\r\nHello, World!\r\nmatthew@ubuntu:~$ ")
            scheduler.ingest(update, at: after(4.05))
            #expect(scheduler.flush(at: after(5)).map(\.text) == ["Hello, World!", "matthew@ubuntu:~$"], "direct keys: \(directKeys)")
        }
    }

    /// Same case, but with the app's heuristic prompt detection running after each flush,
    /// exactly as SpeechCoordinator does. This is the path that dropped the output.
    @Test func outputIsSpokenWithHeuristicPromptDetection() {
        for directKeys in [false, true] {
            let terminal = TerminalEmulator(columns: 60, rows: 10)
            var scheduler = OutputSpeechScheduler(settings: VoiceOverSettings())
            scheduler.speaksAllTypedText = directKeys
            let detector = HeuristicPromptDetector()
            var clock = start
            func step(_ text: String = "", typed: String? = nil, submit: Bool = false) -> [String] {
                clock = clock.addingTimeInterval(1)
                if let typed { scheduler.noteUserTyped(typed, at: clock) }
                if submit { scheduler.noteUserSubmitted(at: clock) }
                if !text.isEmpty { scheduler.ingest(terminal.feed(text), at: clock.addingTimeInterval(0.01)) }
                let spoken = scheduler.flush(at: clock.addingTimeInterval(0.6)).map(\.text)
                let line = terminal.logicalLineText(atAbsoluteRow: terminal.cursorPosition.row)
                if detector.isLikelyPrompt(line) { terminal.recordHeuristicPrompt() }
                return spoken
            }
            _ = step("matthew@ubuntu:~$ ")
            if directKeys {
                _ = step("echo \"Hello, World!\"", typed: "echo \"Hello, World!\"")
                #expect(step("\r\nHello, World!\r\nmatthew@ubuntu:~$ ", submit: true) == ["Hello, World!", "matthew@ubuntu:~$"])
                // And again for a second command.
                _ = step("echo again", typed: "echo again")
                #expect(step("\r\nagain\r\nmatthew@ubuntu:~$ ", submit: true) == ["again", "matthew@ubuntu:~$"])
            } else {
                terminal.noteHeuristicCommandSubmitted(commandLine: "echo \"Hello, World!\"")
                #expect(step("echo \"Hello, World!\"\r\nHello, World!\r\nmatthew@ubuntu:~$ ", submit: true) == ["Hello, World!", "matthew@ubuntu:~$"])
            }
        }
    }

    @Test func typedEchoIsNotRepeatedButCompletionIs() {
        let terminal = TerminalEmulator(columns: 40, rows: 5)
        var scheduler = OutputSpeechScheduler(settings: VoiceOverSettings())
        scheduler.ingest(terminal.feed("$ "), at: start)
        _ = scheduler.flush(at: after(1))

        scheduler.noteUserTyped("cd Doc", at: after(2))
        scheduler.ingest(terminal.feed("cd Doc"), at: after(2.01))
        #expect(scheduler.flush(at: after(2.5)).isEmpty)

        scheduler.noteUserTyped("\t", at: after(3))
        scheduler.ingest(terminal.feed("uments/"), at: after(3.02))
        #expect(scheduler.flush(at: after(3.5)).map(\.text) == ["uments/"])
    }

    @Test func historyRecallSpeaksTheReplacedCommand() {
        let terminal = TerminalEmulator(columns: 40, rows: 5)
        var scheduler = OutputSpeechScheduler(settings: VoiceOverSettings())
        scheduler.ingest(terminal.feed("$ "), at: start)
        _ = scheduler.flush(at: after(1))
        scheduler.noteUserTyped("\u{1B}[A", at: after(2))
        scheduler.ingest(terminal.feed("git status"), at: after(2.02))
        #expect(scheduler.flush(at: after(2.6)).map(\.text) == ["git status"])
    }

    @Test func overflowSpeaksLastLinesAndKeepsAllForReadNewOutput() {
        let terminal = TerminalEmulator(columns: 40, rows: 5)
        var settings = VoiceOverSettings()
        settings.maximumLinesPerAnnouncement = 2
        var scheduler = OutputSpeechScheduler(settings: settings)
        scheduler.ingest(terminal.feed((1...5).map { "line \($0)\r\n" }.joined()), at: start)
        let spoken = scheduler.flush(at: after(1))
        #expect(spoken.first?.text == "5 lines. Last lines:\nline 4\nline 5")
        #expect(scheduler.takeUnreadOutput() == "line 1\nline 2\nline 3\nline 4\nline 5")
        #expect(scheduler.takeUnreadOutput() == nil)
    }

    @Test func manualModeSpeaksNothingButAccumulates() {
        let terminal = TerminalEmulator(columns: 40, rows: 5)
        var settings = VoiceOverSettings()
        settings.automaticReading = .manual
        var scheduler = OutputSpeechScheduler(settings: settings)
        scheduler.ingest(terminal.feed("hello\r\n$ "), at: start)
        #expect(scheduler.flush(at: after(1)).isEmpty)
        #expect(scheduler.takeUnreadOutput() == "hello")
    }

    @Test func importantOnlyModeSpeaksErrors() {
        let terminal = TerminalEmulator(columns: 60, rows: 5)
        var settings = VoiceOverSettings()
        settings.automaticReading = .speakImportantOnly
        var scheduler = OutputSpeechScheduler(settings: settings)
        scheduler.ingest(terminal.feed("compiling\r\nerror: missing semicolon\r\ndone\r\n"), at: start)
        #expect(scheduler.flush(at: after(1)).map(\.text) == ["error: missing semicolon"])
    }

    @Test func synchronizedOutputIsHeldUntilFrameEnds() {
        let terminal = TerminalEmulator(columns: 40, rows: 5)
        var scheduler = OutputSpeechScheduler(settings: VoiceOverSettings())
        scheduler.ingest(terminal.feed("\u{1B}[?2026hframe\r\n"), at: start)
        #expect(scheduler.nextFlushDate == nil)
        #expect(scheduler.flush(at: after(5)).isEmpty)
        scheduler.ingest(terminal.feed("\u{1B}[?2026l"), at: after(5))
        #expect(scheduler.flush(at: after(6)).first?.text == "frame")
    }

    @Test func pausedSchedulerStaysSilent() {
        let terminal = TerminalEmulator(columns: 40, rows: 5)
        var scheduler = OutputSpeechScheduler(settings: VoiceOverSettings())
        scheduler.togglePause()
        scheduler.ingest(terminal.feed("quiet\r\n"), at: start)
        #expect(scheduler.flush(at: after(1)).isEmpty)
        #expect(scheduler.takeUnreadOutput() == "quiet")
    }
}

@Suite("Speech text")
struct SpeechTextTests {
    @Test func boxDrawingAndRulesAreRemoved() {
        let settings = VoiceOverSettings()
        #expect(SpeechTextFilter.clean("│ Name    │ Size │", settings: settings) == "Name Size")
        #expect(SpeechTextFilter.clean("==== Results ====", settings: settings) == "Results")
        #expect(SpeechTextFilter.clean("a -- b", settings: settings) == "a -- b")
    }

    @Test func errorClassification() {
        #expect(ErrorLineClassifier.classify("bash: foo: command not found") == .error)
        #expect(ErrorLineClassifier.classify("Build failed with 2 errors") == .error)
        #expect(ErrorLineClassifier.classify("warning: unused variable") == .warning)
        #expect(ErrorLineClassifier.classify("0 errors, 0 warnings") == nil)
        #expect(ErrorLineClassifier.classify("mirror of terror") == nil)
    }

    @Test func promptHeuristics() {
        let detector = HeuristicPromptDetector()
        #expect(detector.isLikelyPrompt("matt@server:~$ "))
        #expect(detector.isLikelyPrompt("root@box:/# "))
        #expect(detector.isLikelyPrompt("❯ "))
        #expect(!detector.isLikelyPrompt("Downloading 45%"))
        #expect(detector.isLikelyPrompt("Password: "))
        #expect(detector.isSecretPrompt("[sudo] password for matt: "))
        #expect(!detector.isLikelyPrompt(":"))
    }
}

@Suite("Screen analysis and navigation")
struct NavigationTests {
    @Test func menuSelectionChangesAreSpoken() {
        let terminal = TerminalEmulator(columns: 30, rows: 6)
        var monitor = AlternateScreenMonitor(reading: .highlightAndCursorLine)
        let settings = VoiceOverSettings()
        terminal.feed("\u{1B}[?1049h\u{1B}[1;1H Install\u{1B}[2;1H\u{1B}[7m Configure \u{1B}[0m\u{1B}[3;1H Quit")
        _ = monitor.describeChanges(lines: terminal.screenLines, cursorRow: 1, settings: settings)
        terminal.feed("\u{1B}[2;1H Configure \u{1B}[3;1H\u{1B}[7m Quit      \u{1B}[0m")
        let spoken = monitor.describeChanges(lines: terminal.screenLines, cursorRow: 2, settings: settings)
        #expect(spoken?.text == "Quit")
    }

    @Test func describeScreenMentionsLastCommand() {
        let terminal = TerminalEmulator(columns: 40, rows: 6)
        terminal.feed("\u{1B}]133;A\u{07}$ \u{1B}]133;B\u{07}make\r\n\u{1B}]133;C\u{07}boom\r\n\u{1B}]133;D;2\u{07}\u{1B}]133;A\u{07}$ ")
        let description = ScreenDescriber.describe(terminal)
        #expect(description.contains("Last command: make, exit status 2."))
        #expect(description.contains("Cursor on row 3, column 3."))
    }

    @Test func navigatesByPromptCommandAndError() throws {
        let terminal = TerminalEmulator(columns: 40, rows: 20)
        let A = "\u{1B}]133;A\u{07}", B = "\u{1B}]133;B\u{07}", C = "\u{1B}]133;C\u{07}"
        terminal.feed("\(A)$ \(B)one\r\n\(C)ok\r\n\u{1B}]133;D;0\u{07}")
        terminal.feed("\(A)$ \(B)\r\n")  // empty Return: a prompt but no command
        terminal.feed("\(A)$ \(B)two\r\n\(C)fine\r\nerror: bad\r\n\u{1B}]133;D;1\u{07}\(A)$ \(B)")
        let end = terminal.cursorPosition.row
        let previousCommand = try #require(SemanticNavigator.command(.previous, from: end, in: terminal))
        #expect(previousCommand.commandLine == "two")
        let earlier = try #require(SemanticNavigator.command(.previous, from: previousCommand.promptStart.row, in: terminal))
        #expect(earlier.commandLine == "one")
        let prompts = terminal.commands.count
        #expect(prompts == 4)
        let errorRow = try #require(SemanticNavigator.errorRow(.next, from: 0, in: terminal))
        #expect(terminal.logicalLineText(atAbsoluteRow: errorRow) == "error: bad")
        #expect(SemanticNavigator.errorRow(.previous, from: errorRow, in: terminal) == nil)
        #expect(SemanticNavigator.lastCommandOutput(in: terminal) == "fine\nerror: bad")
        #expect(SemanticNavigator.lastCommandDescription(in: terminal) == "two. Exit status 1.")
    }

    @Test func completionAnnouncements() {
        var settings = VoiceOverSettings()
        let base = Date(timeIntervalSinceReferenceDate: 0)
        var command = TerminalCommand(
            id: 1, source: .shellIntegration, phase: .finished, promptStart: TerminalPosition(row: 0, column: 0),
            inputStart: nil, outputStart: TerminalPosition(row: 1, column: 0), outputEnd: TerminalPosition(row: 2, column: 0),
            commandLine: "make -j8", isCommandLineReported: true, exitStatus: 2, workingDirectory: nil,
            startedAt: base, finishedAt: base.addingTimeInterval(3)
        )
        #expect(AnnouncementComposer.commandFinished(command, settings: settings)?.text == "Command failed with exit status 2.")
        settings.includeCommandInCompletion = true
        #expect(AnnouncementComposer.commandFinished(command, settings: settings)?.text == "make failed with exit status 2.")
        command.exitStatus = 0
        #expect(AnnouncementComposer.commandFinished(command, settings: settings) == nil)
        command.finishedAt = base.addingTimeInterval(75)
        #expect(AnnouncementComposer.commandFinished(command, settings: settings)?.text == "make finished after 1 minute 15 seconds.")
        command.exitStatus = 130
        #expect(AnnouncementComposer.commandFinished(command, settings: settings)?.text
            == "make was interrupted after 1 minute 15 seconds, with exit status 130.")
    }
}

@Suite("Direct keys speech")
struct DirectKeysSpeechTests {
    let start = Date(timeIntervalSinceReferenceDate: 5_000)
    func after(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    @Test func typedCharactersDeletionsAndOutputAreAllSpoken() {
        let terminal = TerminalEmulator(columns: 40, rows: 5)
        var scheduler = OutputSpeechScheduler(settings: VoiceOverSettings())
        scheduler.speaksAllTypedText = true
        scheduler.ingest(terminal.feed("$ "), at: start)
        _ = scheduler.flush(at: after(1))

        scheduler.noteUserTyped("l", at: after(2))
        scheduler.ingest(terminal.feed("l"), at: after(2.01))
        #expect(scheduler.flush(at: after(2.5)).map(\.text) == ["l"])

        scheduler.noteUserTyped("s", at: after(3))
        scheduler.ingest(terminal.feed("s"), at: after(3.01))
        #expect(scheduler.flush(at: after(3.5)).map(\.text) == ["s"])

        scheduler.noteUserTyped(" ", at: after(4))
        scheduler.ingest(terminal.feed(" "), at: after(4.01))
        #expect(scheduler.flush(at: after(4.5)).map(\.text) == ["space"])

        scheduler.noteUserTyped("x", at: after(5))
        scheduler.ingest(terminal.feed("x"), at: after(5.01))
        #expect(scheduler.flush(at: after(5.5)).map(\.text) == ["x"])

        scheduler.noteUserTyped("\u{7F}", at: after(6))
        scheduler.ingest(terminal.feed("\u{8} \u{8}"), at: after(6.01))
        #expect(scheduler.flush(at: after(6.5)).map { $0.text } == ["x"])
        #expect(scheduler.flush(at: after(6.5)).isEmpty)

        scheduler.noteUserSubmitted(at: after(7))
        scheduler.ingest(terminal.feed("\r\nfile.txt\r\n$ "), at: after(7.05))
        #expect(scheduler.flush(at: after(8)).map(\.text) == ["file.txt", "$"])
    }

    @Test func editorCursorMovesSpeakTheCharacter() {
        let terminal = TerminalEmulator(columns: 20, rows: 3)
        terminal.feed("\u{1B}[?1049h\u{1B}[Hab cd")
        var monitor = AlternateScreenMonitor(reading: .highlightAndCursorLine)
        let settings = VoiceOverSettings()
        _ = monitor.describeChanges(lines: terminal.screenLines, cursorRow: 0, cursorColumn: 5, settings: settings)
        #expect(monitor.describeChanges(lines: terminal.screenLines, cursorRow: 0, cursorColumn: 2, settings: settings)?.text == "space")
        #expect(monitor.describeChanges(lines: terminal.screenLines, cursorRow: 0, cursorColumn: 1, settings: settings)?.text == "b")
        #expect(monitor.describeChanges(lines: terminal.screenLines, cursorRow: 0, cursorColumn: 9, settings: settings)?.text == "blank")
        // Typing a space at the end of "ab cd" (cursor 5 → 6, text unchanged).
        _ = monitor.describeChanges(lines: terminal.screenLines, cursorRow: 0, cursorColumn: 5, settings: settings)
        #expect(monitor.describeChanges(lines: terminal.screenLines, cursorRow: 0, cursorColumn: 6, settings: settings)?.text == "space")
    }

    @Test func editorTypingSpeaksOnlyTheChange() {
        #expect(AlternateScreenMonitor.edit(from: "hello wor", to: "hello world")?.text == "ld")
        #expect(AlternateScreenMonitor.edit(from: "hello world", to: "hello wold")?.isDeletion == true)
        #expect(AlternateScreenMonitor.edit(from: "abc", to: "a completely different line") == nil)
    }
}
