import Foundation

/// Errors from the SSH layer, each with a plain-language explanation and the technical
/// detail needed for troubleshooting. Raw libssh2 codes never reach the UI unexplained.
public enum SSHError: Error, Sendable, Equatable {
    case hostNotFound(host: String)
    case connectionRefused(host: String, port: Int)
    case connectionTimedOut(host: String, seconds: Int)
    case networkUnavailable(detail: String)
    case connectionLost(detail: String)
    case handshakeFailed(detail: String)
    case hostKeyUnavailable
    /// The server rejected the credentials.
    case authenticationFailed(method: String)
    /// None of the methods the person configured are accepted by the server.
    case noAcceptedAuthenticationMethod(serverMethods: [String])
    case privateKeyUnreadable(detail: String)
    case passphraseRequired
    case channelFailed(detail: String)
    case notConnected
    case cancelled
    case protocolError(code: Int32, detail: String)

    /// One or two sentences suitable for an alert and for VoiceOver.
    public var userMessage: String {
        switch self {
        case let .hostNotFound(host):
            "AcceSSH couldn’t find a server named “\(host)”. Check the host name and your internet connection."
        case let .connectionRefused(host, port):
            "\(host) refused the connection on port \(port). The SSH service may not be running, or it may use a different port."
        case let .connectionTimedOut(host, seconds):
            "\(host) didn’t respond within \(seconds) seconds. The server may be offline, or a firewall may be blocking the connection."
        case .networkUnavailable:
            "No network connection is available."
        case .connectionLost:
            "The connection to the server was lost."
        case .handshakeFailed:
            "AcceSSH couldn’t set up a secure connection with the server. The server may require an encryption method AcceSSH doesn’t support."
        case .hostKeyUnavailable:
            "The server didn’t provide a host key, so its identity can’t be verified."
        case let .authenticationFailed(method):
            "The server rejected the \(method). Check your user name and credentials."
        case let .noAcceptedAuthenticationMethod(methods):
            methods.isEmpty
                ? "The server didn’t accept any of the sign-in methods set up for this host."
                : "The server only accepts \(Self.list(methods.map(Self.methodName))). Set up one of those for this host."
        case .privateKeyUnreadable:
            "AcceSSH couldn’t read the private key. It may be damaged or in an unsupported format."
        case .passphraseRequired:
            "This private key is protected by a passphrase. Enter the passphrase to use it."
        case .channelFailed:
            "The server refused to open a terminal session."
        case .notConnected:
            "This session isn’t connected."
        case .cancelled:
            "The connection was cancelled."
        case .protocolError:
            "An SSH protocol error occurred."
        }
    }

    /// Details for the “Technical details” disclosure and logs.
    public var technicalDetail: String? {
        switch self {
        case let .networkUnavailable(detail), let .connectionLost(detail), let .handshakeFailed(detail),
             let .privateKeyUnreadable(detail), let .channelFailed(detail):
            detail
        case let .protocolError(code, detail):
            "libssh2 error \(code): \(detail)"
        case let .noAcceptedAuthenticationMethod(methods):
            "Server methods: \(methods.joined(separator: ", "))"
        default:
            nil
        }
    }

    static func methodName(_ wireName: String) -> String {
        switch wireName {
        case "publickey": "public keys"
        case "password": "passwords"
        case "keyboard-interactive": "keyboard-interactive sign-in"
        case "hostbased": "host-based authentication"
        default: wireName
        }
    }

    static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: ""
        case 1: items[0]
        case 2: "\(items[0]) and \(items[1])"
        default: items.dropLast().joined(separator: ", ") + ", and " + items[items.count - 1]
        }
    }
}

extension SSHError: LocalizedError {
    public var errorDescription: String? { userMessage }
}
