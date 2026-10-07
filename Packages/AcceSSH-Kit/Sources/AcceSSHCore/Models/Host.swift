import Foundation

/// A saved connection target. Contains no secrets: passwords and private keys are referenced
/// by identifier and live in the Keychain (see ``AuthenticationConfiguration``).
public struct Host: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    /// Name shown in the host list and spoken by VoiceOver. Falls back to `hostname`.
    public var displayName: String
    /// DNS name or IP address literal (IPv4 or IPv6).
    public var hostname: String
    /// Additional addresses tried in order if `hostname` cannot be reached.
    public var alternateAddresses: [String]
    public var port: Int
    public var username: String
    public var authentication: AuthenticationConfiguration
    /// Another saved host used as an SSH jump host (ProxyJump equivalent).
    public var jumpHostID: UUID?
    /// Overrides `TerminalSettings.terminalType` when set (for example `xterm-256color`).
    public var terminalType: String?
    /// Command typed into the shell after the session becomes ready.
    public var startupCommand: String?
    /// Directory to `cd` into after login, if set.
    public var workingDirectory: String?
    public var environment: [EnvironmentVariable]
    public var connection: ConnectionOptions
    public var portForwards: [PortForward]
    public var profiles: HostProfileReferences
    public var shellIntegration: ShellIntegrationPreference
    /// Input mode for sessions with this host; `nil` uses the keyboard settings.
    public var inputMode: InputModePreference?
    public var groupID: UUID?
    public var isFavorite: Bool
    public var notes: String
    public var createdAt: Date
    public var lastConnectedAt: Date?

    public init(
        id: UUID = UUID(),
        displayName: String = "",
        hostname: String,
        alternateAddresses: [String] = [],
        port: Int = 22,
        username: String,
        authentication: AuthenticationConfiguration = AuthenticationConfiguration(),
        jumpHostID: UUID? = nil,
        terminalType: String? = nil,
        startupCommand: String? = nil,
        workingDirectory: String? = nil,
        environment: [EnvironmentVariable] = [],
        connection: ConnectionOptions = ConnectionOptions(),
        portForwards: [PortForward] = [],
        profiles: HostProfileReferences = HostProfileReferences(),
        shellIntegration: ShellIntegrationPreference = .automatic,
        groupID: UUID? = nil,
        isFavorite: Bool = false,
        notes: String = "",
        createdAt: Date = Date(),
        lastConnectedAt: Date? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.hostname = hostname
        self.alternateAddresses = alternateAddresses
        self.port = port
        self.username = username
        self.authentication = authentication
        self.jumpHostID = jumpHostID
        self.terminalType = terminalType
        self.startupCommand = startupCommand
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.connection = connection
        self.portForwards = portForwards
        self.profiles = profiles
        self.shellIntegration = shellIntegration
        self.groupID = groupID
        self.isFavorite = isFavorite
        self.notes = notes
        self.createdAt = createdAt
        self.lastConnectedAt = lastConnectedAt
    }

    /// The name to show and speak for this host.
    public var effectiveDisplayName: String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? hostname : trimmed
    }

    /// `user@host` or `user@host:port` when the port is non-standard.
    public var connectionSummary: String {
        let base = username.isEmpty ? hostname : "\(username)@\(hostname)"
        return port == 22 ? base : "\(base):\(port)"
    }

    /// Validation problems that prevent connecting, phrased for display and speech.
    public var validationProblems: [String] {
        var problems: [String] = []
        if hostname.trimmingCharacters(in: .whitespaces).isEmpty {
            problems.append("Enter a host name or IP address.")
        }
        if !(1...65535).contains(port) {
            problems.append("The port must be between 1 and 65535.")
        }
        if jumpHostID == id {
            problems.append("A host cannot use itself as its jump host.")
        }
        problems.append(contentsOf: environment.compactMap(\.validationProblem))
        return problems
    }
}

/// A folder that groups hosts in the host list.
public struct HostGroup: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var parentID: UUID?
    public var sortIndex: Int

    public init(id: UUID = UUID(), name: String, parentID: UUID? = nil, sortIndex: Int = 0) {
        self.id = id
        self.name = name
        self.parentID = parentID
        self.sortIndex = sortIndex
    }
}

/// An environment variable requested for the remote session. Servers only honor variables
/// listed in their `AcceptEnv` configuration; rejected variables are reported, not fatal.
public struct EnvironmentVariable: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var value: String

    public init(id: UUID = UUID(), name: String, value: String) {
        self.id = id
        self.name = name
        self.value = value
    }

    var validationProblem: String? {
        guard let first = name.unicodeScalars.first else {
            return "An environment variable is missing its name."
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
        let isValid = name.unicodeScalars.allSatisfy { $0.isASCII && allowed.contains($0) }
            && !CharacterSet.decimalDigits.contains(first)
        return isValid ? nil : "“\(name)” is not a valid environment variable name."
    }
}

/// Transport-level options for a host.
public struct ConnectionOptions: Codable, Hashable, Sendable {
    /// Seconds to wait for TCP connect plus SSH handshake.
    public var connectTimeout: TimeInterval
    /// Seconds between SSH keepalive messages; `nil` disables keepalive.
    public var keepAliveInterval: TimeInterval?
    /// Unanswered keepalives before the connection is considered lost.
    public var keepAliveMaxMissed: Int
    public var reconnectPolicy: ReconnectPolicy
    public var compression: Bool
    public var addressFamily: AddressFamilyPreference
    /// Forward the in-app key agent to the server. Off by default: a compromised server can
    /// use a forwarded agent for as long as the session lasts.
    public var agentForwarding: Bool
    /// Reconnect this host automatically when AcceSSH relaunches. Off by default; the
    /// app never reconnects to a host on launch unless the person turned this on.
    public var reconnectOnLaunch: Bool

    public init(
        connectTimeout: TimeInterval = 15,
        keepAliveInterval: TimeInterval? = 30,
        keepAliveMaxMissed: Int = 3,
        reconnectPolicy: ReconnectPolicy = .ask,
        compression: Bool = false,
        addressFamily: AddressFamilyPreference = .automatic,
        agentForwarding: Bool = false,
        reconnectOnLaunch: Bool = false
    ) {
        self.connectTimeout = connectTimeout
        self.keepAliveInterval = keepAliveInterval
        self.keepAliveMaxMissed = keepAliveMaxMissed
        self.reconnectPolicy = reconnectPolicy
        self.compression = compression
        self.addressFamily = addressFamily
        self.agentForwarding = agentForwarding
        self.reconnectOnLaunch = reconnectOnLaunch
    }
}

public enum AddressFamilyPreference: String, Codable, CaseIterable, Sendable {
    case automatic, ipv4Only, ipv6Only
}

/// What to do when an established connection drops unexpectedly.
public enum ReconnectPolicy: Codable, Hashable, Sendable {
    /// Leave the session disconnected.
    case never
    /// Offer a Reconnect action and announce it; do nothing until the person chooses.
    case ask
    /// Retry automatically with exponential backoff.
    case automatic(maxAttempts: Int, initialDelay: TimeInterval, maxDelay: TimeInterval)

    public static let standardAutomatic = ReconnectPolicy.automatic(maxAttempts: 5, initialDelay: 1, maxDelay: 30)

    /// Delay before the given 1-based attempt, or `nil` when no further attempt should happen.
    public func delay(beforeAttempt attempt: Int) -> TimeInterval? {
        guard case let .automatic(maxAttempts, initialDelay, maxDelay) = self,
              attempt >= 1, attempt <= maxAttempts else { return nil }
        let exponent = Double(min(attempt - 1, 16))
        return min(maxDelay, initialDelay * pow(2, exponent))
    }
}

/// How AcceSSH should treat accessibility shell integration for a host.
public enum ShellIntegrationPreference: String, Codable, CaseIterable, Sendable {
    /// Use integration if the remote shell reports it; never install or inject anything.
    case automatic
    /// After login, type a `source` command for the integration script installed under
    /// `~/.accessh`. Requires the script to have been installed with the person's approval.
    case activateOnConnect
    /// Ignore all integration messages and rely on heuristics only.
    case disabled
}

/// Profiles a host uses. `nil` means "use the global default profile".
public struct HostProfileReferences: Codable, Hashable, Sendable {
    public var appearance: UUID?
    public var terminal: UUID?
    public var keyboard: UUID?
    public var toolbar: UUID?
    public var accessibility: UUID?
    public var sound: UUID?
    public var haptic: UUID?
    public var bell: UUID?

    public init(
        appearance: UUID? = nil, terminal: UUID? = nil, keyboard: UUID? = nil, toolbar: UUID? = nil,
        accessibility: UUID? = nil, sound: UUID? = nil, haptic: UUID? = nil, bell: UUID? = nil
    ) {
        self.appearance = appearance
        self.terminal = terminal
        self.keyboard = keyboard
        self.toolbar = toolbar
        self.accessibility = accessibility
        self.sound = sound
        self.haptic = haptic
        self.bell = bell
    }
}
