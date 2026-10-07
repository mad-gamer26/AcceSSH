import Foundation

/// The AcceSSH accessibility shell-integration protocol.
///
/// Integration travels in-band over the existing terminal byte stream as OSC
/// (Operating System Command) escape sequences, so it needs no extra network service and
/// survives `sudo -i`, `tmux` passthrough-free sessions, jump hosts and serial consoles.
///
/// Three OSC families are understood:
///
/// | OSC  | Origin | Used for |
/// |------|--------|----------|
/// | 133  | FinalTerm convention (iTerm2, WezTerm, kitty, Ghostty, fish 4 …) | prompt / command / output marks |
/// | 633  | VS Code shell integration | marks, command line, cwd |
/// | 6973 | AcceSSH | handshake, capabilities, command line, cwd, host, user, notifications |
///
/// AcceSSH scripts emit OSC 133 for marks (so they cooperate with other terminals) and
/// OSC 6973 for everything else. OSC 6973 messages are
/// `ESC ] 6973 ; <event> [; <key>=<value>]* BEL` where values are percent-encoded
/// (at least `%`, `;`, control characters). Unknown events and keys are ignored, which is
/// how the protocol stays backward compatible. See `Documentation/Developer/ShellIntegrationProtocol.md`.
public enum ShellIntegrationProtocol {
    /// The protocol version this build of AcceSSH implements.
    public static let version = 1
    public static let acceSSHOSC = 6973
    public static let finalTermOSC = 133
    public static let vsCodeOSC = 633
    /// Payloads longer than this are dropped to bound memory use from hostile output.
    public static let maximumPayloadLength = 8_192
}

/// Prompt kinds from OSC 133 `A`/`P` `k=` parameters.
public enum PromptKind: String, Sendable, Equatable {
    /// Primary prompt (PS1).
    case initial = "i"
    /// Continuation prompt (PS2).
    case continuation = "c"
    /// Secondary/right prompt.
    case secondary = "s"
    /// Right-side prompt.
    case right = "r"
}

/// Where a message came from. Positional marks from all sources are treated alike;
/// only AcceSSH's own `hello` carries version, capabilities and the session token.
public enum ShellIntegrationOrigin: String, Codable, Sendable, Equatable {
    case acceSSH
    case finalTerm
    case vsCode
}

public struct ShellIntegrationHello: Sendable, Equatable {
    public var protocolVersion: Int
    public var shell: String?
    public var scriptVersion: String?
    public var capabilities: ShellIntegrationCapabilities
    public var hostname: String?
    public var username: String?
    public var token: String?

    public init(
        protocolVersion: Int, shell: String? = nil, scriptVersion: String? = nil,
        capabilities: ShellIntegrationCapabilities = [], hostname: String? = nil,
        username: String? = nil, token: String? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.shell = shell
        self.scriptVersion = scriptVersion
        self.capabilities = capabilities
        self.hostname = hostname
        self.username = username
        self.token = token
    }
}

public enum NotificationUrgency: String, Sendable, Equatable {
    case low, normal, critical
}

/// A decoded shell-integration message.
public enum ShellIntegrationMessage: Sendable, Equatable {
    /// OSC 133;A — a prompt begins at the cursor.
    case promptStarted(PromptKind)
    /// OSC 133;B — the prompt ended; command input begins at the cursor.
    case promptEnded
    /// OSC 133;C — the command was submitted; its output begins at the cursor.
    case commandExecuted
    /// OSC 133;D[;status] — the command finished.
    case commandFinished(exitStatus: Int32?)
    /// The exact command line, reported just before `commandExecuted`.
    case commandLine(String)
    case workingDirectory(String)
    case hostname(String)
    case username(String)
    case title(String)
    case hello(ShellIntegrationHello)
    case notification(title: String?, body: String, urgency: NotificationUrgency)
    case outputStarted
    case outputEnded
    /// A well-formed AcceSSH message this version does not understand.
    case unknown(event: String)
}

public enum ShellIntegrationDecoder {
    /// Decodes the payload of an OSC sequence (everything after `<code>;`).
    /// Returns `nil` for OSC codes that are not shell integration or malformed payloads.
    public static func decode(oscCode: Int, payload: Substring) -> (ShellIntegrationMessage, ShellIntegrationOrigin)? {
        guard payload.utf8.count <= ShellIntegrationProtocol.maximumPayloadLength else { return nil }
        switch oscCode {
        case ShellIntegrationProtocol.finalTermOSC:
            return decodeFinalTerm(payload).map { ($0, .finalTerm) }
        case ShellIntegrationProtocol.vsCodeOSC:
            return decodeVSCode(payload).map { ($0, .vsCode) }
        case ShellIntegrationProtocol.acceSSHOSC:
            return decodeAcceSSH(payload).map { ($0, .acceSSH) }
        default:
            return nil
        }
    }

    static func decodeFinalTerm(_ payload: Substring) -> ShellIntegrationMessage? {
        let parts = payload.split(separator: ";", omittingEmptySubsequences: false)
        guard let kind = parts.first else { return nil }
        let options = parseOptions(parts.dropFirst())
        switch kind {
        case "A":
            return .promptStarted(options["k"].flatMap { PromptKind(rawValue: String($0)) } ?? .initial)
        case "P":
            // Kitty-style "prompt start" with kind; only primary prompts start a new command.
            let promptKind = options["k"].flatMap { PromptKind(rawValue: String($0)) } ?? .initial
            return promptKind == .initial ? .promptStarted(.initial) : nil
        case "B":
            return .promptEnded
        case "C":
            return .commandExecuted
        case "D":
            let status = parts.count > 1 ? Int32(parts[1].trimmingCharacters(in: .whitespaces)) : nil
            return .commandFinished(exitStatus: status)
        default:
            return nil
        }
    }

    static func decodeVSCode(_ payload: Substring) -> ShellIntegrationMessage? {
        let parts = payload.split(separator: ";", maxSplits: 2, omittingEmptySubsequences: false)
        guard let kind = parts.first else { return nil }
        switch kind {
        case "A": return .promptStarted(.initial)
        case "B": return .promptEnded
        case "C": return .commandExecuted
        case "D":
            let status = parts.count > 1 ? Int32(parts[1]) : nil
            return .commandFinished(exitStatus: status)
        case "E":
            // 633;E;<commandline>[;<nonce>] with `\\` and `\x3b` escapes.
            guard parts.count > 1 else { return nil }
            let line = parts[1]
            return .commandLine(decodeVSCodeEscapes(line))
        case "P":
            guard parts.count > 1 else { return nil }
            let property = parts[1...].joined(separator: ";")
            if property.hasPrefix("Cwd=") {
                return .workingDirectory(decodeVSCodeEscapes(property.dropFirst(4)))
            }
            return nil
        default:
            return nil
        }
    }

    static func decodeAcceSSH(_ payload: Substring) -> ShellIntegrationMessage? {
        let parts = payload.split(separator: ";", omittingEmptySubsequences: false)
        guard let event = parts.first, !event.isEmpty else { return nil }
        let fields = parseOptions(parts.dropFirst())
        func field(_ key: String) -> String? {
            fields[key].map { ShellIntegrationCoding.percentDecode($0) }
        }
        switch event {
        case "hello":
            let capabilities = ShellIntegrationCapabilities(
                parsing: field("caps") ?? ""
            )
            return .hello(ShellIntegrationHello(
                protocolVersion: field("v").flatMap(Int.init) ?? 1,
                shell: field("shell"),
                scriptVersion: field("sv"),
                capabilities: capabilities,
                hostname: field("host").flatMap(nonEmpty),
                username: field("user").flatMap(nonEmpty),
                token: field("token").flatMap(nonEmpty)
            ))
        case "command":
            // `cmd` is omitted when the shell withholds the command line for privacy.
            guard let command = field("cmd") else { return .unknown(event: "command") }
            return .commandLine(command)
        case "cwd":
            return field("path").map(ShellIntegrationMessage.workingDirectory)
        case "host":
            return field("name").map(ShellIntegrationMessage.hostname)
        case "user":
            return field("name").map(ShellIntegrationMessage.username)
        case "title":
            return field("text").map(ShellIntegrationMessage.title)
        case "notify":
            guard let body = field("body") else { return nil }
            let urgency = field("urgency").flatMap(NotificationUrgency.init(rawValue:)) ?? .normal
            return .notification(title: field("title"), body: body, urgency: urgency)
        case "output-start":
            return .outputStarted
        case "output-end":
            return .outputEnded
        default:
            return .unknown(event: String(event))
        }
    }

    private static func nonEmpty(_ value: String) -> String? { value.isEmpty ? nil : value }

    private static func parseOptions(_ parts: ArraySlice<Substring>) -> [String: Substring] {
        var options: [String: Substring] = [:]
        for part in parts {
            guard let equals = part.firstIndex(of: "=") else { continue }
            let key = String(part[..<equals])
            if options[key] == nil {
                options[key] = part[part.index(after: equals)...]
            }
        }
        return options
    }

    private static func decodeVSCodeEscapes<S: StringProtocol>(_ text: S) -> String {
        var result = ""
        var iterator = Array(text.unicodeScalars)[...]
        while let scalar = iterator.popFirst() {
            guard scalar == "\\" else { result.unicodeScalars.append(scalar); continue }
            if iterator.first == "\\" {
                iterator.removeFirst()
                result.append("\\")
            } else if iterator.count >= 3, iterator.first == "x" {
                let hex = String(String.UnicodeScalarView(iterator.dropFirst().prefix(2)))
                if let value = UInt8(hex, radix: 16) {
                    iterator.removeFirst(3)
                    result.unicodeScalars.append(Unicode.Scalar(value))
                } else {
                    result.append("\\")
                }
            } else {
                result.append("\\")
            }
        }
        return result
    }
}

/// Percent coding used inside OSC 6973 values.
public enum ShellIntegrationCoding {
    /// Lenient percent-decoding: invalid escapes are kept literally and the result is
    /// interpreted as UTF-8 with replacement characters for invalid sequences.
    public static func percentDecode<S: StringProtocol>(_ text: S) -> String {
        let source = Array(text.utf8)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(source.count)
        var index = 0
        while index < source.count {
            let byte = source[index]
            if byte == UInt8(ascii: "%"), index + 2 < source.count,
               let high = hexValue(source[index + 1]), let low = hexValue(source[index + 2]) {
                bytes.append(high << 4 | low)
                index += 3
            } else {
                bytes.append(byte)
                index += 1
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Encodes `%`, `;`, `=` and C0/DEL control characters, which is the minimum needed for a
    /// value to survive inside an OSC 6973 field. Mirrors the shell scripts' encoder.
    public static func percentEncode(_ text: String) -> String {
        var result = ""
        for byte in text.utf8 {
            switch byte {
            case UInt8(ascii: "%"), UInt8(ascii: ";"), UInt8(ascii: "="), 0..<0x20, 0x7F:
                result += String(format: "%%%02X", byte)
            default:
                result.unicodeScalars.append(Unicode.Scalar(byte))
            }
        }
        // Re-decode as UTF-8: the loop above appended raw bytes as Latin-1 scalars.
        return String(decoding: result.unicodeScalars.map { UInt8($0.value) }, as: UTF8.self)
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): byte - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): byte - UInt8(ascii: "A") + 10
        default: nil
        }
    }
}
