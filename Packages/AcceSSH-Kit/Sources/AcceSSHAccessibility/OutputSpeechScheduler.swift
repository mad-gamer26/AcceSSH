import Foundation
import AcceSSHCore
import AcceSSHTerminal

/// Decides what new terminal output to speak and when.
///
/// The scheduler is a pure state machine: the session feeds it ``TerminalUpdate``s and
/// keystroke notifications with timestamps, and asks ``flush(at:force:)`` for utterances
/// whenever ``nextFlushDate`` passes. It never talks to VoiceOver itself, which keeps it
/// deterministic and testable. The platform layer posts the utterances.
///
/// Policy:
/// - Output is coalesced until it has been quiet for `coalescingInterval`, or until
///   `maximumLatency` has passed during a continuous stream.
/// - Large batches are reduced with the configured overflow strategy, and everything not
///   spoken stays available through ``takeUnreadOutput()`` ("Read New Output").
/// - The echo of what the person typed is not spoken again; text the remote side inserts
///   that the person did not type (tab completion, history recall) is.
/// - Synchronized-output frames (mode 2026) are spoken only once complete.
public struct OutputSpeechScheduler: Sendable {
    public var settings: VoiceOverSettings
    public private(set) var isPaused = false
    /// Speak every character the server echoes, every deletion and all output, instead of
    /// assuming VoiceOver already spoke what was typed. Used for direct-keys input, where keys
    /// go straight to the server and the screen is the only record of what was typed.
    public var speaksAllTypedText = false

    private var pendingLines: [String] = []
    private var pendingCount = 0
    private var firstPendingAt: Date?
    private var lastOutputAt: Date?
    private var lastUserInputAt: Date?
    private var typedSinceFlush = ""
    private var awaitingSubmitEcho = false
    private var cursorLine: String?
    private var cursorLineKind: LineSemanticKind = .unknown
    private var knownCursorLine = ""
    private var cursorOffset = 0
    private var knownCursorOffset = 0
    private var cursorCharacter: Character?
    private var promptPending = false
    private var holdForSynchronizedOutput = false
    private var unread: [String] = []
    private let unreadLimit = 5_000
    private let echoWindow: TimeInterval = 0.6

    public init(settings: VoiceOverSettings) {
        self.settings = settings
    }

    // MARK: Input

    /// The person typed text that will be sent to the remote side.
    public mutating func noteUserTyped(_ text: String, at date: Date) {
        typedSinceFlush += text
        lastUserInputAt = date
    }

    /// The person pressed Return.
    public mutating func noteUserSubmitted(at date: Date) {
        awaitingSubmitEcho = true
        typedSinceFlush = ""
        lastUserInputAt = date
        knownCursorLine = ""
    }

    /// Ingests one emulator update.
    public mutating func ingest(_ update: TerminalUpdate, at date: Date) {
        for event in update.events {
            switch event {
            case let .synchronizedOutputChanged(active):
                holdForSynchronizedOutput = active && settings.respectSynchronizedOutput
            case .promptStarted:
                promptPending = true
            default:
                break
            }
        }

        var received = false
        for line in update.committedLines {
            received = true
            // The first line completed after Return is the echo of the command just entered.
            // Nothing else is skipped: speech never depends on guessed line types, which can
            // misclassify output when there's no shell integration.
            let isSubmitEcho = awaitingSubmitEcho
            awaitingSubmitEcho = false
            if settings.suppressCommandEcho && isSubmitEcho { continue }
            let cleaned = SpeechTextFilter.clean(line.text, settings: settings)
            appendUnread(cleaned)
            if cleaned.isEmpty, pendingLines.last?.isEmpty ?? true { continue }
            pendingLines.append(cleaned)
            pendingCount += 1
        }

        if !update.isAlternateScreen, let text = update.cursorLineText, text != cursorLine {
            cursorLine = text
            cursorLineKind = update.cursorLineKind
            received = true
        }
        if !update.isAlternateScreen {
            cursorOffset = update.cursorLineOffset
            cursorCharacter = update.cursorCharacter
        }
        if speaksAllTypedText, update.cursorMoved || !update.changedRows.isEmpty {
            // A typed space moves the cursor without changing the (trimmed) line text.
            received = true
        }
        if !update.committedLines.isEmpty {
            // A new line began; what was known about the previous cursor line no longer applies.
            knownCursorLine = ""
        }
        if received {
            lastOutputAt = date
            if firstPendingAt == nil { firstPendingAt = date }
        }
    }

    // MARK: Output

    /// When the caller should next call ``flush(at:force:)``, or `nil` if nothing is pending.
    public var nextFlushDate: Date? {
        guard let lastOutputAt, let firstPendingAt, !holdForSynchronizedOutput else { return nil }
        return min(lastOutputAt.addingTimeInterval(settings.coalescingInterval),
                   firstPendingAt.addingTimeInterval(settings.maximumLatency))
    }

    /// Produces utterances that are due. `force` speaks pending output immediately.
    public mutating func flush(at date: Date, force: Bool = false) -> [SpeechUtterance] {
        guard let lastOutputAt, let firstPendingAt else { return [] }
        if holdForSynchronizedOutput && !force { return [] }
        let quiet = date.timeIntervalSince(lastOutputAt) >= settings.coalescingInterval
        let overdue = date.timeIntervalSince(firstPendingAt) >= settings.maximumLatency
        guard quiet || overdue || force else { return [] }

        var utterances: [SpeechUtterance] = []
        if !isPaused, let output = outputUtterance() {
            utterances.append(output)
        }
        let hadLines = pendingCount > 0
        pendingLines.removeAll()
        pendingCount = 0
        self.firstPendingAt = nil

        // The cursor line is only evaluated once output has settled, so that partially
        // drawn prompts are not spoken.
        if quiet || force {
            if !isPaused, let cursorUtterance = cursorLineUtterance(afterOutput: hadLines, at: date) {
                utterances.append(cursorUtterance)
            }
            knownCursorLine = cursorLine ?? ""
            knownCursorOffset = cursorOffset
            typedSinceFlush = ""
            promptPending = false
            self.lastOutputAt = nil
        }
        return utterances
    }

    private func outputUtterance() -> SpeechUtterance? {
        var lines = pendingLines
        while lines.last?.isEmpty == true { lines.removeLast() }
        while lines.first?.isEmpty == true { lines.removeFirst() }
        guard !lines.isEmpty else { return nil }

        switch settings.automaticReading {
        case .manual, .speakPromptsOnly:
            return nil
        case .speakImportantOnly:
            lines = lines.filter { ErrorLineClassifier.classify($0) == .error }
            guard !lines.isEmpty else { return nil }
        case .speakEverything, .speakNewLines:
            break
        }

        let limit = max(1, settings.maximumLinesPerAnnouncement)
        let total = lines.count
        var text: String
        if total <= limit {
            text = lines.joined(separator: "\n")
        } else {
            switch settings.overflowStrategy {
            case .speakLastLines:
                text = "\(total) lines. Last lines:\n" + lines.suffix(limit).joined(separator: "\n")
            case .speakFirstLines:
                text = lines.prefix(limit).joined(separator: "\n") + "\n\(total - limit) more lines."
            case .summarize:
                text = "\(total) new lines."
            }
        }
        if text.count > settings.maximumCharactersPerAnnouncement {
            let cut = text.prefix(settings.maximumCharactersPerAnnouncement)
            let boundary = cut.lastIndex(where: { $0 == " " || $0 == "\n" }) ?? cut.endIndex
            text = String(cut[..<boundary]) + "… More output available."
        }
        return SpeechUtterance(text, kind: .output)
    }

    private func cursorLineUtterance(afterOutput hadLines: Bool, at date: Date) -> SpeechUtterance? {
        guard let line = cursorLine else { return nil }
        let mode = settings.automaticReading
        guard mode != .manual else { return nil }
        let known = knownCursorLine
        let isEcho = lastUserInputAt.map { date.timeIntervalSince($0) < echoWindow + settings.coalescingInterval } ?? false

        // A fresh prompt: after output, after a prompt mark, or a new line we have not seen.
        if hadLines || promptPending || known.isEmpty {
            return promptUtterance(line)
        }
        if mode == .speakImportantOnly || mode == .speakPromptsOnly { return nil }

        if speaksAllTypedText {
            return typedTextUtterance(line: line, known: known)
        }

        // Same line edited in place.
        if line.hasPrefix(known) {
            // Cursor-line text has trailing spaces trimmed, so a space after the prompt
            // reappears as part of the insertion; it was not typed, so ignore it here.
            let inserted = String(line.dropFirst(known.count).drop(while: { $0 == " " }))
            guard !inserted.isEmpty else { return nil }
            if isEcho && inserted == typedSinceFlush { return nil }
            if isEcho && typedSinceFlush.hasSuffix(inserted) { return nil }
            guard settings.speakInsertedCompletions else { return nil }
            // Tab completion: speak only what the shell added beyond what was typed.
            let added = inserted.hasPrefix(typedSinceFlush) ? String(inserted.dropFirst(typedSinceFlush.count)) : inserted
            let cleaned = SpeechTextFilter.clean(added, settings: settings)
            return cleaned.isEmpty ? nil : SpeechUtterance(cleaned, kind: .completion)
        }
        if known.hasPrefix(line) {
            let removed = String(known.dropFirst(line.count))
            guard settings.speakDeletedCharacters, !removed.isEmpty else { return nil }
            // A single deleted character after Backspace: VoiceOver convention is to say it.
            return SpeechUtterance(removed, kind: .deletion)
        }
        // The line was replaced, for example by history recall (Up Arrow). Speak the part
        // after the common prefix, which usually omits the unchanged prompt.
        let common = zip(line, known).prefix { $0 == $1 }.count
        let replacement = SpeechTextFilter.clean(String(line.dropFirst(common)), settings: settings)
        return replacement.isEmpty ? nil : SpeechUtterance(replacement, kind: .completion)
    }

    /// Direct-keys echo: speak exactly what changed on the line, or the character the cursor
    /// moved to. Line text has trailing spaces trimmed, so both versions are padded out to the
    /// cursor; otherwise a typed space would be invisible.
    private func typedTextUtterance(line: String, known: String) -> SpeechUtterance? {
        let current = Self.padded(line, to: cursorOffset)
        let previous = Self.padded(known, to: knownCursorOffset)
        if current == previous {
            guard cursorOffset != knownCursorOffset else { return nil }
            return SpeechUtterance(Self.spokenCharacter(cursorCharacter), kind: .completion)
        }
        let prefix = zip(current, previous).prefix { $0 == $1 }.count
        let currentRest = current.dropFirst(prefix)
        let previousRest = previous.dropFirst(prefix)
        let suffix = zip(currentRest.reversed(), previousRest.reversed()).prefix { $0 == $1 }.count
        let inserted = String(currentRest.dropLast(suffix))
        let removed = String(previousRest.dropLast(suffix))
        if !inserted.isEmpty {
            return SpeechUtterance(Self.spokenTyping(inserted), kind: .completion)
        }
        if !removed.isEmpty {
            return SpeechUtterance(Self.spokenTyping(removed), kind: .deletion)
        }
        return nil
    }

    static func padded(_ text: String, to length: Int) -> String {
        text.count >= length ? text : text + String(repeating: " ", count: length - text.count)
    }

    /// How a character under the cursor is spoken.
    static func spokenCharacter(_ character: Character?) -> String {
        guard let character else { return "blank" }
        return character == " " ? "space" : String(character)
    }

    /// Typed text as spoken: short input containing spaces is spelled out ("s space"), so a
    /// typed space is always heard; longer insertions (completions, pastes) are read as text.
    static func spokenTyping(_ text: String) -> String {
        if text.allSatisfy({ $0 == " " }) { return text.count == 1 ? "space" : "\(text.count) spaces" }
        if text.count <= 4, text.contains(" ") {
            return text.map { $0 == " " ? "space" : String($0) }.joined(separator: " ")
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

    private func promptUtterance(_ line: String) -> SpeechUtterance? {
        switch settings.promptReading {
        case .off:
            return nil
        case .announceOnly:
            return SpeechUtterance(settings.promptPhrase, kind: .prompt)
        case .fullText:
            let cleaned = SpeechTextFilter.clean(line, settings: settings)
            return cleaned.isEmpty ? nil : SpeechUtterance(cleaned, kind: .prompt)
        }
    }

    // MARK: Commands

    /// Pauses or resumes automatic speech. Output keeps accumulating for Read New Output.
    @discardableResult
    public mutating func togglePause() -> Bool {
        isPaused.toggle()
        return isPaused
    }

    /// All output received since the last call, for "Read New Output". Clears the buffer.
    public mutating func takeUnreadOutput() -> String? {
        var lines = unread
        unread.removeAll()
        while lines.last?.isEmpty == true { lines.removeLast() }
        while lines.first?.isEmpty == true { lines.removeFirst() }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    public var unreadLineCount: Int { unread.count }

    private mutating func appendUnread(_ line: String) {
        if line.isEmpty, unread.last?.isEmpty == true { return }
        unread.append(line)
        if unread.count > unreadLimit { unread.removeFirst(unread.count - unreadLimit) }
    }
}
