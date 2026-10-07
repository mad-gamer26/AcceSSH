import Foundation

/// Semantic features a shell integration reports it can provide.
public struct ShellIntegrationCapabilities: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let prompts = ShellIntegrationCapabilities(rawValue: 1 << 0)
    public static let commands = ShellIntegrationCapabilities(rawValue: 1 << 1)
    public static let exitStatus = ShellIntegrationCapabilities(rawValue: 1 << 2)
    public static let commandLine = ShellIntegrationCapabilities(rawValue: 1 << 3)
    public static let workingDirectory = ShellIntegrationCapabilities(rawValue: 1 << 4)
    public static let hostname = ShellIntegrationCapabilities(rawValue: 1 << 5)
    public static let username = ShellIntegrationCapabilities(rawValue: 1 << 6)
    public static let notifications = ShellIntegrationCapabilities(rawValue: 1 << 7)
    public static let outputBlocks = ShellIntegrationCapabilities(rawValue: 1 << 8)
    public static let title = ShellIntegrationCapabilities(rawValue: 1 << 9)

    static let names: [(String, ShellIntegrationCapabilities)] = [
        ("prompt", .prompts), ("command", .commands), ("exit", .exitStatus),
        ("commandline", .commandLine), ("cwd", .workingDirectory), ("host", .hostname),
        ("user", .username), ("notify", .notifications), ("output", .outputBlocks), ("title", .title),
    ]

    /// Parses the comma-separated `caps=` list of a `hello` message; unknown names are ignored.
    public init(parsing list: String) {
        var value: ShellIntegrationCapabilities = []
        for name in list.split(separator: ",") {
            if let match = Self.names.first(where: { $0.0 == name.trimmingCharacters(in: .whitespaces) }) {
                value.insert(match.1)
            }
        }
        self = value
    }

    /// Human-readable names, for the Shell Integration settings screen.
    public var displayNames: [String] {
        var names: [String] = []
        if contains(.prompts) { names.append("Prompts") }
        if contains(.commands) { names.append("Commands") }
        if contains(.exitStatus) { names.append("Exit status") }
        if contains(.commandLine) { names.append("Command text") }
        if contains(.workingDirectory) { names.append("Working directory") }
        if contains(.hostname) { names.append("Host name") }
        if contains(.username) { names.append("User name") }
        if contains(.notifications) { names.append("Notifications") }
        if contains(.outputBlocks) { names.append("Output blocks") }
        if contains(.title) { names.append("Title") }
        return names
    }

    /// Capabilities implied by plain OSC 133 marks with no handshake.
    public static let marksOnly: ShellIntegrationCapabilities = [.prompts, .commands, .exitStatus, .outputBlocks]
}

/// Live integration status for one terminal session.
public struct ShellIntegrationState: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        /// No integration messages have been seen. Heuristics are used.
        case notDetected
        /// Standard OSC 133/633 marks are arriving, but not from AcceSSH's own script
        /// (for example fish 4's built-in marks or another terminal's integration).
        case marksOnly
        /// AcceSSH's integration completed its handshake.
        case active
        /// The remote script speaks a newer protocol than this app. Known messages are
        /// still used; the person is told to update AcceSSH.
        case newerProtocol
        /// The person disabled integration for this host; messages are ignored.
        case disabled
    }

    public var status: Status
    public var origin: ShellIntegrationOrigin?
    public var protocolVersion: Int?
    public var scriptVersion: String?
    public var shell: String?
    public var capabilities: ShellIntegrationCapabilities
    /// True when the handshake echoed the token AcceSSH sent in `LC_ACCESSH_TOKEN`,
    /// which shows the messages come from the integration script and not from, say,
    /// `cat` of a file that happens to contain escape sequences.
    public var isTokenVerified: Bool
    public var hostname: String?
    public var username: String?
    public var lastMessageAt: Date?

    public init(
        status: Status = .notDetected, origin: ShellIntegrationOrigin? = nil, protocolVersion: Int? = nil,
        scriptVersion: String? = nil, shell: String? = nil, capabilities: ShellIntegrationCapabilities = [],
        isTokenVerified: Bool = false, hostname: String? = nil, username: String? = nil, lastMessageAt: Date? = nil
    ) {
        self.status = status
        self.origin = origin
        self.protocolVersion = protocolVersion
        self.scriptVersion = scriptVersion
        self.shell = shell
        self.capabilities = capabilities
        self.isTokenVerified = isTokenVerified
        self.hostname = hostname
        self.username = username
        self.lastMessageAt = lastMessageAt
    }

    /// Whether semantic boundaries come from the shell rather than from heuristics.
    public var isAuthoritative: Bool {
        status == .active || status == .marksOnly || status == .newerProtocol
    }

    /// Whether the installed script is older than the one bundled with this app.
    public var isUpdateAvailable: Bool {
        guard status == .active, let scriptVersion else { return false }
        return ShellIntegrationScripts.compareVersions(scriptVersion, ShellIntegrationScripts.scriptVersion) < 0
    }

    /// One-sentence status for the settings screen and VoiceOver.
    public var summary: String {
        switch status {
        case .notDetected:
            return "Shell integration is not active. AcceSSH is using prompt detection."
        case .marksOnly:
            return "Standard shell prompt marks detected. Command text and working directory may be unavailable."
        case .active:
            let shellName = shell ?? "shell"
            let version = scriptVersion.map { " version \($0)" } ?? ""
            let update = isUpdateAvailable ? " An update is available." : ""
            return "Shell integration is active for \(shellName)\(version).\(update)"
        case .newerProtocol:
            return "The remote shell integration is newer than this version of AcceSSH. Basic features still work; update AcceSSH for full support."
        case .disabled:
            return "Shell integration is turned off for this host."
        }
    }
}
