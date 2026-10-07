import Foundation

/// Shells with an AcceSSH integration script.
public enum ShellKind: String, Codable, CaseIterable, Sendable {
    case bash, zsh, fish

    public var displayName: String { rawValue }

    /// Script file name, both in the app bundle and on the remote host.
    public var scriptFileName: String { "accessh.\(rawValue)" }

    /// Where the script is placed on the remote host, relative to `$HOME`.
    public var remoteScriptPath: String { "\(ShellIntegrationScripts.remoteDirectory)/\(scriptFileName)" }

    /// Startup files that may receive the loader block, relative to `$HOME`, in priority order.
    public var startupFiles: [String] {
        switch self {
        // bash login shells (the usual case over SSH) read ~/.bash_profile, not ~/.bashrc.
        case .bash: [".bashrc", ".bash_profile"]
        case .zsh: [".zshrc"]
        case .fish: [".config/fish/config.fish"]
        }
    }

    /// Detects the shell from `$SHELL` or a process name such as `-zsh` or `/usr/bin/fish`.
    public init?(shellPath: String) {
        let name = shellPath.split(separator: "/").last.map(String.init) ?? shellPath
        let trimmed = name.hasPrefix("-") ? String(name.dropFirst()) : name
        self.init(rawValue: trimmed)
    }
}

public enum ShellIntegrationScripts {
    /// Version of the scripts bundled with this build. Bump when any script changes.
    public static let scriptVersion = "1.0.0"

    /// Directory on the remote host, relative to `$HOME`. Everything AcceSSH installs lives here
    /// except the clearly marked loader block in the shell's startup file.
    public static let remoteDirectory = ".accessh/shell-integration"

    /// The script text for a shell, loaded from this package's resources.
    public static func script(for shell: ShellKind) throws -> String {
        guard let url = Bundle.module.url(forResource: "accessh", withExtension: shell.rawValue, subdirectory: "Scripts")
            ?? Bundle.module.url(forResource: "accessh", withExtension: shell.rawValue) else {
            throw ShellIntegrationError.scriptMissing(shell)
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// One-line command that loads the installed script in the current shell only, without
    /// touching any startup file. Used by "Activate on connect". Starts with a space so that
    /// shells configured to ignore space-prefixed commands keep it out of history.
    public static func activationCommand(for shell: ShellKind) -> String {
        switch shell {
        case .bash, .zsh:
            " [ -r \"$HOME/\(shell.remoteScriptPath)\" ] && . \"$HOME/\(shell.remoteScriptPath)\""
        case .fish:
            " test -r \"$HOME/\(shell.remoteScriptPath)\"; and source \"$HOME/\(shell.remoteScriptPath)\""
        }
    }

    /// Compares dotted version strings numerically. Returns -1, 0 or 1.
    public static func compareVersions(_ lhs: String, _ rhs: String) -> Int {
        let a = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let b = rhs.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            if x != y { return x < y ? -1 : 1 }
        }
        return 0
    }
}

public enum ShellIntegrationError: Error, Equatable, LocalizedError {
    case scriptMissing(ShellKind)
    /// The startup file contains a begin marker without an end marker (or vice versa).
    /// AcceSSH refuses to edit it rather than guess where its block ends.
    case damagedBlock(file: String)

    public var errorDescription: String? {
        switch self {
        case let .scriptMissing(shell):
            "The \(shell.displayName) integration script is missing from this copy of AcceSSH."
        case let .damagedBlock(file):
            "The AcceSSH section in \(file) is incomplete, so AcceSSH will not change that file. Remove the lines between the AcceSSH markers yourself, then try again."
        }
    }
}
