import Foundation

/// Naming constants for the product.
///
/// The product is called AcceSSH everywhere: on screen, in VoiceOver, in file and package
/// names, in Swift identifiers, and in remote-side identifiers (the `LC_TERMINAL` value and
/// the `~/.accessh` directory on servers). Lowercase identifiers use `accessh`.
public enum AcceSSHProduct {
    /// The user-facing product name. Use this for every visible string and accessibility label.
    public static let displayName = "AcceSSH"

    /// The identifier used in paths and remote-side names.
    public static let internalName = "AcceSSH"

    /// Value AcceSSH sends as `LC_TERMINAL` so remote shell integration can recognize it.
    /// `LC_*` variables are accepted by the default `AcceptEnv` on most OpenSSH servers.
    public static let terminalEnvironmentValue = "AcceSSH"

    /// Environment variable carrying the per-session shell-integration token.
    public static let integrationTokenEnvironmentKey = "LC_ACCESSH_TOKEN"
}
