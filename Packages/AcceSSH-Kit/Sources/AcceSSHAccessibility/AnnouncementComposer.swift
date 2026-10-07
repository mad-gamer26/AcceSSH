import Foundation
import AcceSSHCore
import AcceSSHTerminal
import AcceSSHShellIntegration

/// Wording for event announcements. Centralized so phrasing stays consistent and short.
public enum AnnouncementComposer {
    /// Announcement for a finished command, or `nil` if settings say to stay silent.
    public static func commandFinished(_ command: TerminalCommand, settings: VoiceOverSettings) -> SpeechUtterance? {
        let name = settings.includeCommandInCompletion ? command.commandLine.flatMap(shortCommandName) : nil
        let subject = name ?? "Command"
        let isLong = settings.longRunningCommandThreshold.map { (command.duration ?? 0) >= $0 } ?? false
        let durationText = isLong ? command.duration.map { " after \(spokenDuration($0))" } ?? "" : ""

        guard let status = command.exitStatus else {
            guard isLong || settings.announceSuccessfulCommands else { return nil }
            return SpeechUtterance("\(subject) finished\(durationText).", priority: .low, kind: .event)
        }
        if status == 0 {
            guard settings.announceSuccessfulCommands || isLong,
                  settings.isEnabled(.commandCompletion) else { return nil }
            return SpeechUtterance("\(subject) finished\(durationText).", priority: .low, kind: .event)
        }
        guard settings.announceFailedCommands, settings.isEnabled(.commandFailure) else { return nil }
        let reason = signalDescription(status)
        let statusText = settings.includeExitStatus ? " with exit status \(status)" : ""
        if let reason {
            return SpeechUtterance("\(subject) \(reason)\(durationText)\(statusText.isEmpty ? "" : ",\(statusText)").", kind: .event)
        }
        return SpeechUtterance("\(subject) failed\(durationText)\(statusText).", kind: .event)
    }

    /// "interrupted" for 130 (SIGINT) and similar for other common signals.
    public static func signalDescription(_ status: Int32) -> String? {
        switch status {
        case 130: "was interrupted"
        case 137: "was killed"
        case 143: "was terminated"
        case 139: "crashed with a segmentation fault"
        case 134: "aborted"
        case 141: "stopped on a broken pipe"
        default: nil
        }
    }

    /// The program name of a command line, for example "make" for "make -j8 all".
    public static func shortCommandName(_ line: String) -> String? {
        let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        // Skip leading environment assignments and sudo.
        let program = words.first { !$0.contains("=") && $0 != "sudo" && $0 != "time" && $0 != "nohup" }
        return program.map { String($0.split(separator: "/").last ?? $0) }
    }

    public static func spokenDuration(_ interval: TimeInterval) -> String {
        let seconds = Int(interval.rounded())
        if seconds < 60 { return "\(seconds) second\(seconds == 1 ? "" : "s")" }
        let minutes = seconds / 60, remainder = seconds % 60
        if minutes < 60 {
            let minuteText = "\(minutes) minute\(minutes == 1 ? "" : "s")"
            return remainder == 0 ? minuteText : "\(minuteText) \(remainder) second\(remainder == 1 ? "" : "s")"
        }
        let hours = minutes / 60, minuteRemainder = minutes % 60
        let hourText = "\(hours) hour\(hours == 1 ? "" : "s")"
        return minuteRemainder == 0 ? hourText : "\(hourText) \(minuteRemainder) minute\(minuteRemainder == 1 ? "" : "s")"
    }

    public static func cursorPosition(row: Int, column: Int) -> String {
        "Row \(row + 1), column \(column + 1)."
    }

    public static func connectionState(_ state: SessionConnectionState, hostName: String) -> SpeechUtterance? {
        switch state {
        case .connected: SpeechUtterance("Connected to \(hostName).", kind: .event)
        case let .disconnected(reason): SpeechUtterance(reason.map { "Disconnected from \(hostName). \($0)" } ?? "Disconnected from \(hostName).", kind: .event)
        case let .failed(message): SpeechUtterance("Connection to \(hostName) failed. \(message)", priority: .high, kind: .event)
        case let .reconnecting(attempt): SpeechUtterance("Connection lost. Reconnecting, attempt \(attempt).", kind: .event)
        case .idle, .connecting, .verifyingHostKey, .authenticating: nil
        }
    }

    public static func shellIntegrationChanged(_ state: ShellIntegrationState) -> SpeechUtterance? {
        switch state.status {
        case .active: SpeechUtterance("Shell integration active.", priority: .low, kind: .event)
        case .newerProtocol: SpeechUtterance(state.summary, priority: .low, kind: .event)
        case .marksOnly, .notDetected, .disabled: nil
        }
    }

    public static func searchResult(index: Int, count: Int, lineText: String) -> String {
        guard count > 0 else { return "No matches." }
        return "Match \(index + 1) of \(count). \(lineText)"
    }
}
