import Foundation

/// Builds transparent, reversible installation plans for shell integration.
///
/// Nothing here touches the network. The plan lists every file that would be created or
/// changed with its complete before/after text, so the UI can show exactly what will
/// happen and require explicit approval. The SFTP layer then applies an approved plan
/// verbatim. Startup-file edits are confined to one delimited block that AcceSSH can
/// later find, update or remove without disturbing anything else in the file.
public enum ShellIntegrationInstaller {
    public static let beginMarker = "# >>> AcceSSH shell integration >>>"
    public static let endMarker = "# <<< AcceSSH shell integration <<<"

    /// When the loader block should source the script.
    public enum LoadCondition: String, Codable, CaseIterable, Sendable {
        /// Only in sessions opened by AcceSSH (detected through `LC_TERMINAL`). This keeps
        /// other terminals unaffected, but needs the server to accept `LC_*` variables,
        /// which OpenSSH's default `AcceptEnv LANG LC_*` does.
        case acceSSHSessionsOnly
        /// In every interactive shell. Use when the server rejects `LC_*` variables. The
        /// sequences are ignored by other terminals.
        case always

        public var explanation: String {
            switch self {
            case .acceSSHSessionsOnly:
                "Load only when you connect with AcceSSH. Other terminal apps are not affected."
            case .always:
                "Load in every interactive shell. Use this if the server does not pass the LC_TERMINAL variable."
            }
        }
    }

    public struct FileChange: Equatable, Sendable, Identifiable {
        public enum Kind: Equatable, Sendable { case create, modify, unchanged }

        /// Path relative to `$HOME`.
        public var path: String
        public var kind: Kind
        /// `nil` when the file does not exist yet.
        public var originalContents: String?
        public var newContents: String
        public var id: String { path }

        /// Lines added and removed, for a readable (and VoiceOver-friendly) summary.
        public var addedLines: [String] { Self.lineDifference(newContents, minus: originalContents ?? "") }
        public var removedLines: [String] { Self.lineDifference(originalContents ?? "", minus: newContents) }

        /// Spoken/visible description, for example "Modify .bashrc: add 6 lines".
        public var summary: String {
            switch kind {
            case .create:
                return "Create \(path) (\(newContents.split(separator: "\n", omittingEmptySubsequences: false).count) lines)"
            case .unchanged:
                return "\(path) is already up to date"
            case .modify where newContents.isEmpty:
                return "Delete \(path)"
            case .modify:
                var parts: [String] = []
                if !addedLines.isEmpty { parts.append("add \(addedLines.count) line\(addedLines.count == 1 ? "" : "s")") }
                if !removedLines.isEmpty { parts.append("remove \(removedLines.count) line\(removedLines.count == 1 ? "" : "s")") }
                return "Modify \(path): \(parts.joined(separator: " and "))"
            }
        }

        static func lineDifference(_ a: String, minus b: String) -> [String] {
            var remaining = b.split(separator: "\n", omittingEmptySubsequences: false).reduce(into: [Substring: Int]()) { $0[$1, default: 0] += 1 }
            var result: [String] = []
            for line in a.split(separator: "\n", omittingEmptySubsequences: false) {
                if let count = remaining[line], count > 0 {
                    remaining[line] = count - 1
                } else {
                    result.append(String(line))
                }
            }
            return result
        }
    }

    public struct Plan: Equatable, Sendable {
        public var shell: ShellKind
        public var changes: [FileChange]
        /// True when nothing would change.
        public var isNoOp: Bool { changes.allSatisfy { $0.kind == .unchanged } }
    }

    /// The loader block for a startup file.
    public static func loaderBlock(for shell: ShellKind, condition: LoadCondition) -> String {
        let script = "$HOME/\(shell.remoteScriptPath)"
        let header = [
            beginMarker,
            "# Added by AcceSSH with your approval. It loads accessibility shell integration",
            "# (prompt, command and exit-status marks for VoiceOver). To remove it, delete this",
            "# block or use Shell Integration > Remove in AcceSSH.",
        ]
        let body: [String]
        switch (shell, condition) {
        case (.bash, .acceSSHSessionsOnly), (.zsh, .acceSSHSessionsOnly):
            body = [
                "if [ \"${LC_TERMINAL:-}\" = \"AcceSSH\" ] && [ -r \"\(script)\" ]; then",
                "    . \"\(script)\"",
                "fi",
            ]
        case (.bash, .always), (.zsh, .always):
            body = [
                "if [ -r \"\(script)\" ]; then",
                "    . \"\(script)\"",
                "fi",
            ]
        case (.fish, .acceSSHSessionsOnly):
            body = [
                "if test \"$LC_TERMINAL\" = \"AcceSSH\"; and test -r \"\(script)\"",
                "    source \"\(script)\"",
                "end",
            ]
        case (.fish, .always):
            body = [
                "if test -r \"\(script)\"",
                "    source \"\(script)\"",
                "end",
            ]
        }
        return (header + body + [endMarker]).joined(separator: "\n")
    }

    /// Range of an existing AcceSSH block (including both marker lines and the newline
    /// after the end marker), or `nil` when absent.
    public static func existingBlockRange(in contents: String, file: String) throws -> Range<String.Index>? {
        let begin = contents.range(of: beginMarker)
        let end = contents.range(of: endMarker)
        switch (begin, end) {
        case (nil, nil):
            return nil
        case let (begin?, end?) where begin.lowerBound < end.lowerBound:
            // Start at the beginning of the begin-marker line.
            let lineStart = contents[..<begin.lowerBound].lastIndex(of: "\n").map { contents.index(after: $0) } ?? contents.startIndex
            var upper = end.upperBound
            if upper < contents.endIndex, contents[upper] == "\n" { upper = contents.index(after: upper) }
            // Refuse if there are several blocks; editing one could leave the other stale.
            if contents[upper...].contains(beginMarker) { throw ShellIntegrationError.damagedBlock(file: file) }
            return lineStart..<upper
        default:
            throw ShellIntegrationError.damagedBlock(file: file)
        }
    }

    /// `contents` with the loader block inserted, or replaced if one exists.
    public static func applyingBlock(_ block: String, to contents: String, file: String) throws -> String {
        if let range = try existingBlockRange(in: contents, file: file) {
            var updated = contents
            updated.replaceSubrange(range, with: block + "\n")
            return updated
        }
        var updated = contents
        if !updated.isEmpty && !updated.hasSuffix("\n") { updated += "\n" }
        if !updated.isEmpty { updated += "\n" }
        return updated + block + "\n"
    }

    /// `contents` with the loader block removed, along with one blank separator line AcceSSH added.
    public static func removingBlock(from contents: String, file: String) throws -> String {
        guard let range = try existingBlockRange(in: contents, file: file) else { return contents }
        var updated = contents
        updated.removeSubrange(range)
        // Remove the blank line inserted before the block on install, if still there.
        if range.lowerBound > updated.startIndex, range.lowerBound <= updated.endIndex {
            let before = updated[..<range.lowerBound]
            if before.hasSuffix("\n\n") { updated.remove(at: updated.index(before: range.lowerBound)) }
        }
        return updated
    }

    /// Whether a bash login file already loads `~/.bashrc` (so a second block is unnecessary).
    public static func bashProfileSourcesBashrc(_ contents: String) -> Bool {
        contents.split(separator: "\n").contains { line in
            let code = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            return code.contains(".bashrc") && (code.contains("source") || code.contains(". ") || code.contains(".\t"))
        }
    }

    /// Builds an installation (or update) plan.
    ///
    /// - Parameters:
    ///   - existingFiles: current contents of the script and startup files, keyed by path
    ///     relative to `$HOME`; a missing key or `nil` value means the file does not exist.
    public static func installPlan(
        shell: ShellKind, condition: LoadCondition, existingFiles: [String: String?]
    ) throws -> Plan {
        let script = try ShellIntegrationScripts.script(for: shell)
        var changes: [FileChange] = []

        let existingScript = existingFiles[shell.remoteScriptPath] ?? nil
        changes.append(FileChange(
            path: shell.remoteScriptPath,
            kind: existingScript == nil ? .create : (existingScript == script ? .unchanged : .modify),
            originalContents: existingScript, newContents: script
        ))

        let block = loaderBlock(for: shell, condition: condition)
        var targets = [shell.startupFiles[0]]
        if shell == .bash {
            // Over SSH bash usually starts as a login shell and reads ~/.bash_profile only.
            // If that file exists and does not load ~/.bashrc, it needs the block too.
            if let profile = existingFiles[".bash_profile"] ?? nil, !bashProfileSourcesBashrc(profile) {
                targets.append(".bash_profile")
            }
        }
        for path in targets {
            let original = existingFiles[path] ?? nil
            let updated = try applyingBlock(block, to: original ?? "", file: path)
            let kind: FileChange.Kind = original == nil ? .create : (original == updated ? .unchanged : .modify)
            changes.append(FileChange(path: path, kind: kind, originalContents: original, newContents: updated))
        }
        return Plan(shell: shell, changes: changes)
    }

    /// Builds a removal plan that strips AcceSSH blocks from every startup file. The script
    /// file itself is reported as a `modify` to empty content only if present; the SFTP layer
    /// deletes files whose new contents are empty and whose path is inside the AcceSSH directory.
    public static func removalPlan(shell: ShellKind, existingFiles: [String: String?]) throws -> Plan {
        var changes: [FileChange] = []
        for path in shell.startupFiles {
            guard let original = existingFiles[path] ?? nil else { continue }
            let updated = try removingBlock(from: original, file: path)
            changes.append(FileChange(path: path, kind: original == updated ? .unchanged : .modify,
                                      originalContents: original, newContents: updated))
        }
        if let script = existingFiles[shell.remoteScriptPath] ?? nil {
            changes.append(FileChange(path: shell.remoteScriptPath, kind: .modify, originalContents: script, newContents: ""))
        }
        return Plan(shell: shell, changes: changes)
    }
}
