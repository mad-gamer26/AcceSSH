import Foundation
import AcceSSHCore

/// Something to say through VoiceOver (UIAccessibility/NSAccessibility announcements).
public struct SpeechUtterance: Equatable, Sendable {
    public enum Priority: Int, Comparable, Sendable {
        /// Queued behind current speech.
        case low
        case normal
        /// May interrupt current speech (errors, host-key warnings).
        case high

        public static func < (lhs: Priority, rhs: Priority) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public enum Kind: Equatable, Sendable {
        case output, prompt, completion, deletion, screenChange, event
    }

    public var text: String
    public var priority: Priority
    public var kind: Kind

    public init(_ text: String, priority: Priority = .normal, kind: Kind) {
        self.text = text
        self.priority = priority
        self.kind = kind
    }
}

/// Cleans terminal text before it is spoken. The underlying model is never altered;
/// this only affects speech.
public enum SpeechTextFilter {
    /// Applies the speech-cleanup settings to one line.
    public static func clean(_ text: String, settings: VoiceOverSettings) -> String {
        var scalars = String.UnicodeScalarView()
        var runScalar: Unicode.Scalar?
        var runLength = 0
        var pendingRun = String.UnicodeScalarView()

        func flushRun() {
            if runLength >= 4 && settings.collapseRepeatedSymbols {
                scalars.append(" ")
            } else {
                scalars.append(contentsOf: pendingRun)
            }
            pendingRun.removeAll()
            runLength = 0
            runScalar = nil
        }

        for scalar in text.unicodeScalars {
            var scalar = scalar
            if settings.skipBoxDrawingCharacters, isBoxDrawing(scalar) { scalar = " " }
            if isRepeatableSymbol(scalar) {
                if scalar == runScalar {
                    runLength += 1
                    pendingRun.append(scalar)
                    continue
                }
                flushRun()
                runScalar = scalar
                runLength = 1
                pendingRun.append(scalar)
                continue
            }
            if runScalar != nil { flushRun() }
            scalars.append(scalar)
        }
        if runScalar != nil { flushRun() }

        // Collapse whitespace runs to a single space.
        var result = ""
        var lastWasSpace = false
        for character in String(scalars) {
            if character == " " || character == "\t" || character == "\u{00A0}" {
                if !lastWasSpace { result.append(" ") }
                lastWasSpace = true
            } else {
                result.append(character)
                lastWasSpace = false
            }
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    /// Box drawing, block elements and the DEC line-drawing scan lines.
    public static func isBoxDrawing(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x2500...0x259F, 0x23BA...0x23BD: true
        default: false
        }
    }

    private static func isRepeatableSymbol(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "-", "=", "_", "*", "#", "~", ".", "+", "/", "\\", "|", "<", ">", "─", "━", "═", "·", "•": true
        default: false
        }
    }
}

/// Classifies output lines that look like errors or warnings, for "Jump to Next Error" and
/// "Speak important messages only". Purely lexical; shell-integration exit statuses
/// are the authoritative failure signal and are used in preference when available.
public enum ErrorLineClassifier {
    public enum Severity: Sendable, Equatable { case error, warning }

    private static let errorPhrases = [
        "error", "fatal", "failed", "failure", "exception", "traceback", "panic", "segmentation fault",
        "permission denied", "no such file or directory", "command not found", "not found", "denied",
        "cannot ", "can't ", "could not", "couldn't", "unable to", "refused", "timed out", "abort",
    ]
    private static let warningPhrases = ["warning", "warn:", "deprecated"]
    /// Phrases that contain error words but report success.
    private static let falsePositives = ["0 errors", "no errors", "0 failed", "error: 0", "errors: 0", "failed: 0", "without error"]

    public static func classify(_ line: String) -> Severity? {
        let lowered = line.lowercased()
        guard !lowered.isEmpty else { return nil }
        if falsePositives.contains(where: lowered.contains) { return nil }
        if errorPhrases.contains(where: { containsWord($0, in: lowered) }) { return .error }
        if warningPhrases.contains(where: { containsWord($0, in: lowered) }) { return .warning }
        return nil
    }

    /// Substring match that requires a word boundary before the phrase, so "terror" or
    /// "mirror" do not count.
    private static func containsWord(_ phrase: String, in text: String) -> Bool {
        var searchRange = text.startIndex..<text.endIndex
        while let found = text.range(of: phrase, range: searchRange) {
            let atStart = found.lowerBound == text.startIndex
            let before = atStart ? nil : text[text.index(before: found.lowerBound)]
            if atStart || !(before!.isLetter || before!.isNumber) {
                if phrase.last == " " || phrase.last == ":" { return true }
                let afterOK = found.upperBound == text.endIndex || !text[found.upperBound].isLetter
                    || text[found.upperBound...].hasPrefix("s") || text[found.upperBound...].hasPrefix("ed")
                if afterOK { return true }
            }
            searchRange = found.upperBound..<text.endIndex
        }
        return false
    }
}

/// Guesses whether the cursor line is a shell prompt when no integration is present.
public struct HeuristicPromptDetector: Sendable {
    /// Characters that typically end a prompt.
    public var terminators: Set<Character>
    public var maximumLength: Int

    public init(terminators: Set<Character> = ["$", "#", "%", ">", "❯", "➜", "λ", "»", "→", ":"], maximumLength: Int = 200) {
        self.terminators = terminators
        self.maximumLength = maximumLength
    }

    /// Whether `line` (the logical line holding the cursor, with the cursor at its end)
    /// looks like a prompt awaiting input.
    public func isLikelyPrompt(_ line: String) -> Bool {
        var trimmed = Substring(line)
        while trimmed.last == " " { trimmed.removeLast() }
        guard !trimmed.isEmpty, trimmed.count <= maximumLength, let last = trimmed.last else { return false }
        guard terminators.contains(last) else { return false }
        // A bare ":" is the `less`/`more` pager prompt and password prompts end in ":" too;
        // only count ":" when it reads like "Password:"-style input requests.
        if last == ":" { return isInputRequest(trimmed) }
        // "45%" or "#1" are output, not prompts.
        if last == "%" || last == "#" {
            let before = trimmed.dropLast().last
            if let before, before.isNumber { return false }
        }
        return true
    }

    /// Prompts that ask for input, such as "Password:" or "Continue? [y/N]:".
    public func isInputRequest<S: StringProtocol>(_ line: S) -> Bool {
        let lowered = line.lowercased()
        return ["password", "passphrase", "username", "login", "continue", "[y/n]", "(yes/no", "proceed", "enter "]
            .contains(where: lowered.contains)
    }

    /// Whether a prompt asks for a secret. Typed text must not be echoed or recorded.
    public func isSecretPrompt<S: StringProtocol>(_ line: S) -> Bool {
        let lowered = line.lowercased()
        return ["password", "passphrase", "passcode", "pin:", "verification code", "one-time"].contains(where: lowered.contains)
    }
}
