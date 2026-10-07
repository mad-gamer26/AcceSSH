import Foundation
import AcceSSHShellIntegration

/// What's installed on a server, found by reading files over SSH.
public struct RemoteIntegrationStatus: Sendable, Equatable {
    /// The login shell's path, for example `/bin/bash`.
    public var shellPath: String
    /// The login shell, if AcceSSH has a script for it.
    public var shell: ShellKind?
    /// Version of the installed script, or `nil` if none is installed.
    public var installedScriptVersion: String?
    /// Startup files (relative to the home folder) that contain the AcceSSH loader block.
    public var filesWithLoaderBlock: [String]
    /// Contents of the files an install or removal would read, keyed by path relative to home.
    /// A `nil` value means the file doesn't exist.
    public var files: [String: String?]

    public var isInstalled: Bool { installedScriptVersion != nil && !filesWithLoaderBlock.isEmpty }

    public var isUpdateAvailable: Bool {
        guard let installedScriptVersion else { return false }
        return ShellIntegrationScripts.compareVersions(installedScriptVersion, ShellIntegrationScripts.scriptVersion) < 0
    }
}

public enum RemoteIntegrationError: Error, LocalizedError, Equatable {
    case unsupportedShell(String)
    case fileChangedSinceReview(String)
    case commandFailed(String)
    case refusedPath(String)

    public var errorDescription: String? {
        switch self {
        case let .unsupportedShell(path):
            "Your login shell is \(path). AcceSSH has shell integration for bash, zsh and fish."
        case let .fileChangedSinceReview(path):
            "\(path) changed on the server after you reviewed the changes, so nothing was changed. Review the changes again."
        case let .commandFailed(detail):
            "The server couldn’t complete the change. \(detail)"
        case let .refusedPath(path):
            "AcceSSH won’t delete \(path) because it’s outside AcceSSH’s own folder."
        }
    }
}

/// Inspects, installs, updates and removes shell integration on a server, over an existing
/// authenticated connection. Every change is described by a ``ShellIntegrationInstaller/Plan``
/// the person reviews first; ``apply(_:)`` refuses to proceed if any file changed after the
/// review, backs up each startup file once before its first modification, and deletes only
/// files inside AcceSSH's own folder.
public struct RemoteShellIntegrationManager: Sendable {
    let connection: SSHConnection
    /// Folder that stands in for the home folder. `nil` means the real home folder; tests use
    /// a temporary folder so they never touch real startup files.
    let baseDirectory: String?

    public init(connection: SSHConnection, baseDirectory: String? = nil) {
        self.connection = connection
        self.baseDirectory = baseDirectory
    }

    /// A shell expression for a path relative to the home (or base) folder.
    func remotePath(_ relative: String) -> String {
        let quoted = "'" + relative.replacingOccurrences(of: "'", with: "'\\''") + "'"
        if let baseDirectory {
            return "'" + baseDirectory.replacingOccurrences(of: "'", with: "'\\''") + "'/" + quoted
        }
        return "\"$HOME\"/" + quoted
    }

    // MARK: Reading

    /// Reads a file; `nil` if it doesn't exist.
    func readFile(_ relative: String) async throws -> String? {
        let path = remotePath(relative)
        let result = try await connection.execute("if [ -f \(path) ]; then cat \(path); else exit 3; fi")
        if result.exitStatus == 3 { return nil }
        guard result.exitStatus == 0 else { throw RemoteIntegrationError.commandFailed(result.errorText) }
        return result.outputText
    }

    /// Finds the login shell and what's installed.
    public func inspect() async throws -> RemoteIntegrationStatus {
        let shellPath = try await connection.execute("printf '%s' \"$SHELL\"").outputText
        let shell = ShellKind(shellPath: shellPath)
        var files: [String: String?] = [:]
        var installedVersion: String?
        var withBlock: [String] = []
        let kinds = shell.map { [$0] } ?? ShellKind.allCases
        for kind in kinds {
            let script = try await readFile(kind.remoteScriptPath)
            files[kind.remoteScriptPath] = script
            if let script, installedVersion == nil { installedVersion = Self.scriptVersion(in: script) }
            for startup in kind.startupFiles {
                let contents = try await readFile(startup)
                files[startup] = contents
                if contents?.contains(ShellIntegrationInstaller.beginMarker) == true { withBlock.append(startup) }
            }
        }
        return RemoteIntegrationStatus(shellPath: shellPath, shell: shell, installedScriptVersion: installedVersion,
                                       filesWithLoaderBlock: withBlock, files: files)
    }

    static func scriptVersion(in script: String) -> String? {
        guard let range = script.range(of: "Script version ") else { return nil }
        let rest = script[range.upperBound...]
        let version = rest.prefix { $0.isNumber || $0 == "." }
        return version.hasSuffix(".") ? String(version.dropLast()) : String(version)
    }

    // MARK: Plans

    public func installPlan(for status: RemoteIntegrationStatus,
                            condition: ShellIntegrationInstaller.LoadCondition) throws -> ShellIntegrationInstaller.Plan {
        guard let shell = status.shell else { throw RemoteIntegrationError.unsupportedShell(status.shellPath) }
        return try ShellIntegrationInstaller.installPlan(shell: shell, condition: condition, existingFiles: status.files)
    }

    public func removalPlan(for status: RemoteIntegrationStatus) throws -> ShellIntegrationInstaller.Plan {
        guard let shell = status.shell else { throw RemoteIntegrationError.unsupportedShell(status.shellPath) }
        return try ShellIntegrationInstaller.removalPlan(shell: shell, existingFiles: status.files)
    }

    // MARK: Applying

    /// Applies a reviewed plan.
    public func apply(_ plan: ShellIntegrationInstaller.Plan) async throws {
        let changes = plan.changes.filter { $0.kind != .unchanged }
        // Nothing is touched if any file changed since the plan was made.
        for change in changes {
            let current = try await readFile(change.path)
            if current != change.originalContents { throw RemoteIntegrationError.fileChangedSinceReview(change.path) }
        }
        // Order so a new shell never loads a missing script: write scripts before editing
        // startup files, and delete scripts only after the startup files no longer load them.
        let isScript = { (change: ShellIntegrationInstaller.FileChange) in
            change.path.hasPrefix(ShellIntegrationScripts.remoteDirectory + "/")
        }
        let writes = changes.filter { isScript($0) && !$0.newContents.isEmpty }
        let startupEdits = changes.filter { !isScript($0) }
        let deletions = changes.filter { isScript($0) && $0.newContents.isEmpty }
        for change in writes + startupEdits + deletions {
            let isAccessHFile = change.path.hasPrefix(ShellIntegrationScripts.remoteDirectory + "/")
            if change.newContents.isEmpty, change.originalContents != nil {
                guard isAccessHFile else { throw RemoteIntegrationError.refusedPath(change.path) }
                try await run("rm -f \(remotePath(change.path))")
                continue
            }
            let path = remotePath(change.path)
            var command = "mkdir -p \"$(dirname \(path))\""
            if change.originalContents != nil, !isAccessHFile {
                // One backup, made before AcceSSH first changes the file; never overwritten.
                let backup = remotePath(change.path + ".accessh-backup")
                command += " && { [ -e \(backup) ] || cp -p \(path) \(backup); }"
            }
            // `cat >` writes through symlinks and keeps the file's permissions.
            command += " && cat > \(path)"
            try await run(command, input: Data(change.newContents.utf8))
        }
        // Remove the AcceSSH folder once it's empty.
        if changes.contains(where: { $0.newContents.isEmpty }) {
            try await run("rmdir \(remotePath(ShellIntegrationScripts.remoteDirectory)) \(remotePath(".accessh")) 2>/dev/null; true")
        }
    }

    private func run(_ command: String, input: Data? = nil) async throws {
        let result = try await connection.execute(command, input: input)
        guard result.exitStatus == 0 else {
            throw RemoteIntegrationError.commandFailed(result.errorText.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}
