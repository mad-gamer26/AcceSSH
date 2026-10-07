import Foundation
import AcceSSHCore
import AcceSSHTerminal
import AcceSSHAccessibility
import UIKit

/// Posts VoiceOver announcements, one at a time.
///
/// iOS doesn't reliably keep several announcements posted in quick succession: a new one
/// tends to replace one that hasn't started yet. So AcceSSH keeps its own queue and posts the
/// next announcement only after VoiceOver reports the current one finished. Anything that
/// piled up meanwhile is combined into a single announcement. Each announcement is also marked
/// to wait behind VoiceOver's own speech, so nothing AcceSSH says ever interrupts.
@MainActor
enum Announcer {
    private static var pending: [String] = []
    private static var speaking: String?
    private static var watchdog: Task<Void, Never>?
    private static var isObserving = false

    static var isVoiceOverRunning: Bool {
        UIAccessibility.isVoiceOverRunning
    }

    /// Announces plain text (queued, never interrupting).
    static func announce(_ text: String) {
        post(SpeechUtterance(text, kind: .event))
    }

    static func post(_ utterance: SpeechUtterance) {
        guard !utterance.text.isEmpty else { return }
        observeCompletion()
        pending.append(utterance.text)
        postNext()
    }

    private static func postNext() {
        guard speaking == nil, !pending.isEmpty else { return }
        let text = pending.joined(separator: "\n")
        pending.removeAll()
        speaking = text
        UIAccessibility.post(notification: .announcement, argument: NSAttributedString(string: text, attributes: [
            .accessibilitySpeechQueueAnnouncement: true,
            .accessibilitySpeechAnnouncementPriority: UIAccessibilityPriority.default,
        ]))
        // If VoiceOver never reports completion (for example it was turned off mid-sentence),
        // move on after a generous estimate of the speaking time.
        watchdog?.cancel()
        let seconds = min(60, 4 + Double(text.count) * 0.12)
        watchdog = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            finished(text)
        }
    }

    private static func finished(_ text: String) {
        guard speaking == text else { return }
        speaking = nil
        watchdog?.cancel()
        postNext()
    }

    private static func observeCompletion() {
        guard !isObserving else { return }
        isObserving = true
        NotificationCenter.default.addObserver(forName: UIAccessibility.announcementDidFinishNotification,
                                               object: nil, queue: .main) { note in
            let text = note.userInfo?[UIAccessibility.announcementStringValueUserInfoKey] as? String
            MainActor.assumeIsolated {
                if let text { finished(text) } else if let speaking { finished(speaking) }
            }
        }
        NotificationCenter.default.addObserver(forName: UIAccessibility.voiceOverStatusDidChangeNotification,
                                               object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                if !UIAccessibility.isVoiceOverRunning {
                    pending.removeAll()
                    speaking = nil
                    watchdog?.cancel()
                }
            }
        }
    }
}

/// Turns terminal updates into VoiceOver speech for one session, using the platform-
/// independent policy in AcceSSHAccessibility.
@MainActor
final class SpeechCoordinator {
    var settings: VoiceOverSettings {
        didSet {
            scheduler.settings = settings
            alternateMonitor.reading = settings.alternateScreenReading
        }
    }

    private var scheduler: OutputSpeechScheduler
    private var alternateMonitor: AlternateScreenMonitor
    private var flushTask: Task<Void, Never>?
    private weak var terminal: TerminalEmulator?
    private var pendingAlternateChange = false
    private let promptDetector = HeuristicPromptDetector()
    private(set) var lastAnnouncement: String?
    /// Called when the cursor line looks like a password prompt (true) or stops looking like one.
    var onSecretPromptChange: ((Bool) -> Void)?

    init(settings: VoiceOverSettings, terminal: TerminalEmulator) {
        self.settings = settings
        self.terminal = terminal
        scheduler = OutputSpeechScheduler(settings: settings)
        alternateMonitor = AlternateScreenMonitor(reading: settings.alternateScreenReading)
    }

    var isPaused: Bool { scheduler.isPaused }

    /// Speak every echoed character, deletion and line of output (direct-keys input).
    var speaksAllTypedText: Bool {
        get { scheduler.speaksAllTypedText }
        set { scheduler.speaksAllTypedText = newValue }
    }

    func noteTyped(_ text: String) { scheduler.noteUserTyped(text, at: Date()) }
    func noteSubmitted() { scheduler.noteUserSubmitted(at: Date()) }

    func ingest(_ update: TerminalUpdate) {
        scheduler.ingest(update, at: Date())
        for event in update.events {
            if case let .alternateScreenChanged(active) = event {
                alternateMonitor.reset()
                if active { pendingAlternateChange = true }
            }
        }
        if update.isAlternateScreen, !update.changedRows.isEmpty || update.cursorMoved {
            pendingAlternateChange = true
        }
        scheduleFlush()
    }

    private func scheduleFlush() {
        let deadline = scheduler.nextFlushDate ?? (pendingAlternateChange ? Date().addingTimeInterval(settings.coalescingInterval) : nil)
        guard let deadline else { return }
        flushTask?.cancel()
        flushTask = Task { [weak self] in
            let delay = max(0, deadline.timeIntervalSinceNow)
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    private func flush() {
        let now = Date()
        var utterances = scheduler.flush(at: now)
        if pendingAlternateChange, let terminal, terminal.isAlternateScreenActive, !scheduler.isPaused,
           settings.automaticReading != .manual {
            pendingAlternateChange = false
            if let change = alternateMonitor.describeChanges(lines: terminal.screenLines,
                                                             cursorRow: terminal.cursorScreenPosition.row,
                                                             cursorColumn: terminal.cursorScreenPosition.column, settings: settings) {
                utterances.append(change)
            }
        }
        if let terminal, !terminal.isAlternateScreenActive {
            let line = terminal.logicalLineText(atAbsoluteRow: terminal.cursorPosition.row)
            if promptDetector.isLikelyPrompt(line) { terminal.recordHeuristicPrompt() }
            onSecretPromptChange?(promptDetector.isSecretPrompt(line) && promptDetector.isLikelyPrompt(line))
        }
        // Output and the prompt that follows it go out as one announcement, in order.
        if !utterances.isEmpty {
            say(SpeechUtterance(utterances.map(\.text).joined(separator: "\n"), kind: utterances[0].kind))
        }
        if scheduler.nextFlushDate != nil { scheduleFlush() }
    }

    func say(_ utterance: SpeechUtterance) {
        lastAnnouncement = utterance.text
        guard Announcer.isVoiceOverRunning else { return }
        Announcer.post(utterance)
    }

    func say(_ text: String, priority: SpeechUtterance.Priority = .normal) {
        say(SpeechUtterance(text, priority: priority, kind: .event))
    }

    // MARK: Commands

    func togglePause() -> Bool { scheduler.togglePause() }

    func takeUnreadOutput() -> String? { scheduler.takeUnreadOutput() }

    func repeatLastAnnouncement() {
        if let lastAnnouncement { say(lastAnnouncement) } else { say("Nothing has been announced yet.") }
    }
}
