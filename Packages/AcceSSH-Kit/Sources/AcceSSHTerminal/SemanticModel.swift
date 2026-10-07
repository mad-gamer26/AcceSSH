import Foundation
import AcceSSHShellIntegration

/// Prompts, commands and output blocks, positioned in absolute terminal coordinates.
///
/// Boundaries come from shell integration when available (authoritative) or from
/// heuristics otherwise; each ``TerminalCommand`` records which. Heuristic records are
/// never created while integration is active, so the two never disagree.
struct SemanticModel {
    static let maximumCommands = 5_000

    var commands: [TerminalCommand] = []
    var nextID: UInt64 = 1
    var integration = ShellIntegrationState()
    var pendingCommandLine: String?
    var workingDirectory: String?

    var current: TerminalCommand? { commands.last }

    mutating func makeID() -> UInt64 {
        defer { nextID += 1 }
        return nextID
    }

    mutating func append(_ command: TerminalCommand) {
        commands.append(command)
        if commands.count > Self.maximumCommands { commands.removeFirst(commands.count - Self.maximumCommands) }
    }

    /// Drops commands whose content has been evicted from scrollback entirely.
    mutating func prune(before firstRow: Int) {
        guard let first = commands.first, first.promptStart.row < firstRow else { return }
        commands.removeAll { command in
            let lastRow = command.outputEnd?.row ?? command.outputStart?.row ?? command.inputStart?.row ?? command.promptStart.row
            return lastRow < firstRow && command.phase == .finished
        }
    }

    mutating func resetPhase() {
        if let index = commands.indices.last, commands[index].phase != .finished {
            commands[index].phase = .finished
        }
        pendingCommandLine = nil
    }

    /// Index of the command whose prompt, input or output contains `position`.
    func commandIndex(containing position: TerminalPosition) -> Int? {
        var low = 0, high = commands.count - 1, found: Int?
        while low <= high {
            let mid = (low + high) / 2
            if commands[mid].promptStart <= position {
                found = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return found
    }

    func commandID(containing position: TerminalPosition) -> UInt64? {
        commandIndex(containing: position).map { commands[$0].id }
    }

    /// Semantic role of the content at `position`.
    func kind(of position: TerminalPosition) -> LineSemanticKind {
        guard let index = commandIndex(containing: position) else { return .unknown }
        let command = commands[index]
        if let outputStart = command.outputStart, position >= TerminalPosition(row: outputStart.row, column: 0) {
            if let end = command.outputEnd, position.row > end.row { return .unknown }
            // A line that starts on the row where output began is output (the echo of the
            // command line is on an earlier row).
            return .output
        }
        if let inputStart = command.inputStart {
            return position.row >= inputStart.row && position.row > command.promptStart.row ? .commandInput : .prompt
        }
        return .prompt
    }
}

// MARK: - Public semantic API

extension TerminalEmulator {
    /// Commands known for this session, oldest first.
    public var commands: [TerminalCommand] { semantics.commands }

    /// The most recent command record (possibly still at its prompt).
    public var currentCommand: TerminalCommand? { semantics.current }

    /// The most recent command that actually ran.
    public var lastExecutedCommand: TerminalCommand? { semantics.commands.last { $0.didExecute } }

    public var shellIntegrationState: ShellIntegrationState { semantics.integration }

    public func command(id: UInt64) -> TerminalCommand? { semantics.commands.first { $0.id == id } }

    /// Output blocks of finished commands, oldest first.
    public var outputBlocks: [TerminalOutputBlock] { semantics.commands.compactMap(TerminalOutputBlock.init(command:)) }

    /// Semantic role of the content at an absolute position.
    public func semanticKind(at position: TerminalPosition) -> LineSemanticKind { semantics.kind(of: position) }

    /// The command whose prompt, input or output contains `position`.
    public func command(containing position: TerminalPosition) -> TerminalCommand? {
        semantics.commandIndex(containing: position).map { semantics.commands[$0] }
    }

    /// Text of a command's output, or `nil` if it has not started or has scrolled away.
    public func outputText(of command: TerminalCommand) -> String? {
        guard let start = command.outputStart else { return nil }
        let end = command.outputEnd ?? cursorPosition
        guard start.row >= firstAvailableRow else { return nil }
        return text(from: start, to: end).trimmingCharacters(in: .newlines)
    }

    // MARK: Shell integration

    func applyShellIntegration(_ message: ShellIntegrationMessage, origin: ShellIntegrationOrigin) {
        guard !isShellIntegrationDisabled else { return }
        let now = clock()
        noteIntegrationMessage(message, origin: origin, at: now)

        // Marks describe positions on the primary screen; shells never draw prompts on the
        // alternate screen, so marks arriving there are stray output and are ignored.
        let isPositional: Bool = switch message {
        case .promptStarted, .promptEnded, .commandExecuted, .commandFinished, .outputStarted: true
        default: false
        }
        if isPositional && isAlternateScreenActive { return }
        let position = cursorPosition

        switch message {
        case .promptStarted:
            startPrompt(at: position, source: .shellIntegration, now: now)

        case .promptEnded:
            guard let index = semantics.commands.indices.last else { return }
            let phase = semantics.commands[index].phase
            if phase == .prompt || phase == .input {
                semantics.commands[index].inputStart = position
                semantics.commands[index].phase = .input
            }

        case let .commandLine(line):
            semantics.pendingCommandLine = line

        case .commandExecuted, .outputStarted:
            beginExecution(at: position, now: now)

        case let .commandFinished(status):
            finishCommand(at: position, exitStatus: status, now: now)

        case let .workingDirectory(path):
            guard path != workingDirectory else { return }
            workingDirectory = path
            semantics.workingDirectory = path
            if let index = semantics.commands.indices.last, semantics.commands[index].phase != .finished {
                semantics.commands[index].workingDirectory = path
            }
            update.events.append(.workingDirectoryChanged(path))

        case let .hostname(name):
            semantics.integration.hostname = name
        case let .username(name):
            semantics.integration.username = name
        case let .title(text):
            setTitle(text)
        case let .notification(title, body, urgency):
            update.events.append(.remoteNotification(
                title: title.map { Self.sanitizedTitle($0) }, body: Self.sanitizedTitle(body), urgency: urgency
            ))
        case .hello, .outputEnded, .unknown:
            break
        }
    }

    private func noteIntegrationMessage(_ message: ShellIntegrationMessage, origin: ShellIntegrationOrigin, at now: Date) {
        var state = semantics.integration
        state.lastMessageAt = now
        let before = semantics.integration
        if case let .hello(hello) = message {
            state.status = hello.protocolVersion > ShellIntegrationProtocol.version ? .newerProtocol : .active
            state.origin = .acceSSH
            state.protocolVersion = hello.protocolVersion
            state.scriptVersion = hello.scriptVersion
            state.shell = hello.shell
            state.capabilities = hello.capabilities
            state.hostname = hello.hostname ?? state.hostname
            state.username = hello.username ?? state.username
            if let expected = expectedIntegrationToken, !expected.isEmpty {
                state.isTokenVerified = hello.token == expected
            }
        } else if state.status == .notDetected {
            switch message {
            case .promptStarted, .promptEnded, .commandExecuted, .commandFinished:
                state.status = .marksOnly
                state.origin = origin
                state.capabilities = .marksOnly
            default:
                break
            }
        }
        semantics.integration = state
        var comparableBefore = before, comparableAfter = state
        comparableBefore.lastMessageAt = nil
        comparableAfter.lastMessageAt = nil
        if comparableBefore != comparableAfter {
            update.events.append(.shellIntegrationChanged(state))
        }
    }

    private func startPrompt(at position: TerminalPosition, source: TerminalCommand.Source, now: Date) {
        if let index = semantics.commands.indices.last {
            let last = semantics.commands[index]
            switch last.phase {
            case .running:
                // Prompt without a finish mark (e.g. the command was killed): close it.
                finishCommand(at: position, exitStatus: nil, now: now)
            case .prompt, .input:
                // Shells redraw the prompt in place (resize, Control-L, async themes). Keep one record.
                if last.promptStart.row == position.row || last.inputStart.map({ $0.row == position.row }) == true {
                    semantics.commands[index].promptStart = TerminalPosition(row: position.row, column: min(position.column, last.promptStart.column))
                    semantics.commands[index].phase = .prompt
                    return
                }
                semantics.commands[index].phase = .finished
            case .finished:
                break
            }
        }
        let command = TerminalCommand(
            id: semantics.makeID(), source: source, phase: .prompt, promptStart: position,
            inputStart: nil, outputStart: nil, outputEnd: nil, commandLine: nil, isCommandLineReported: false,
            exitStatus: nil, workingDirectory: semantics.workingDirectory, startedAt: nil, finishedAt: nil
        )
        semantics.append(command)
        if source == .shellIntegration { update.events.append(.promptStarted(commandID: command.id)) }
    }

    private func beginExecution(at position: TerminalPosition, now: Date) {
        guard let index = semantics.commands.indices.last else { return }
        let phase = semantics.commands[index].phase
        guard phase == .prompt || phase == .input else { return }
        var command = semantics.commands[index]
        command.outputStart = position
        command.startedAt = now
        command.phase = .running
        if let reported = semantics.pendingCommandLine {
            command.commandLine = reported
            command.isCommandLineReported = true
        } else {
            let from = command.inputStart ?? command.promptStart
            let extracted = text(from: from, to: position).trimmingCharacters(in: .whitespacesAndNewlines)
            command.commandLine = extracted.isEmpty ? nil : extracted
        }
        semantics.pendingCommandLine = nil
        semantics.commands[index] = command
        update.events.append(.commandStarted(command))
    }

    private func finishCommand(at position: TerminalPosition, exitStatus: Int32?, now: Date) {
        guard let index = semantics.commands.indices.last, semantics.commands[index].phase == .running else {
            semantics.pendingCommandLine = nil
            return
        }
        semantics.commands[index].outputEnd = position
        semantics.commands[index].exitStatus = exitStatus
        semantics.commands[index].finishedAt = now
        semantics.commands[index].phase = .finished
        update.events.append(.commandFinished(semantics.commands[index]))
    }

    // MARK: Heuristics (used only when no integration is present)

    /// Records a prompt detected by pattern matching. The accessibility layer calls this
    /// when output has settled and the cursor line looks like a prompt. Returns `true` if a
    /// new prompt was recorded. Ignored when shell integration is providing marks.
    @discardableResult
    public func recordHeuristicPrompt() -> Bool {
        guard !semantics.integration.isAuthoritative, !isAlternateScreenActive else { return false }
        let cursorRow = cursorPosition.row
        let lineStart = logicalLineRange(containingAbsoluteRow: cursorRow).lowerBound
        let promptStart = TerminalPosition(row: lineStart, column: 0)
        if let last = semantics.current, last.phase != .finished, last.promptStart.row == lineStart {
            semantics.commands[semantics.commands.count - 1].inputStart = cursorPosition
            return false
        }
        let now = clock()
        startPrompt(at: promptStart, source: .heuristic, now: now)
        if let index = semantics.commands.indices.last {
            semantics.commands[index].inputStart = cursorPosition
            semantics.commands[index].phase = .input
        }
        return true
    }

    /// Tells the semantic model the person pressed Return at a heuristic prompt, so the
    /// following output can be grouped as that command's output.
    public func noteHeuristicCommandSubmitted(commandLine: String?) {
        guard !semantics.integration.isAuthoritative, let index = semantics.commands.indices.last,
              semantics.commands[index].source == .heuristic, semantics.commands[index].phase == .input else { return }
        let lineRange = logicalLineRange(containingAbsoluteRow: cursorPosition.row)
        if let commandLine, !commandLine.isEmpty {
            semantics.pendingCommandLine = commandLine
        }
        beginExecution(at: TerminalPosition(row: lineRange.upperBound + 1, column: 0), now: clock())
    }
}
