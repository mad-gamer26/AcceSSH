import Foundation
import Testing
@testable import AcceSSHTransport
import AcceSSHShellIntegration

/// Install, update, conflict detection and removal against the live server, inside a
/// temporary folder under /tmp so real startup files are never touched.
@Suite("Remote shell integration management", .enabled(if: LiveServer.isConfigured), .serialized)
struct RemoteIntegrationManagerTests {
    let originalBashrc = "# test bashrc\nalias ll='ls -l'\n"
    let originalProfile = "# test profile without bashrc\nexport TEST=1\n"

    func withSandbox(_ body: (SSHConnection, RemoteShellIntegrationManager, String) async throws -> Void) async throws {
        let connection = try await LiveServer.connectAndAuthenticate()
        defer { connection.disconnect() }
        let base = "/tmp/accessh-test-\(UUID().uuidString)"
        _ = try await connection.execute("mkdir -p '\(base)' && cat > '\(base)/.bashrc'", input: Data(originalBashrc.utf8))
        _ = try await connection.execute("cat > '\(base)/.bash_profile'", input: Data(originalProfile.utf8))
        do {
            try await body(connection, RemoteShellIntegrationManager(connection: connection, baseDirectory: base), base)
        } catch {
            _ = try? await connection.execute("rm -rf '\(base)'")
            throw error
        }
        _ = try await connection.execute("rm -rf '\(base)'")
    }

    @Test func installUpdateConflictAndRemove() async throws {
        try await withSandbox { connection, manager, base in
            // Nothing installed yet.
            var status = try await manager.inspect()
            #expect(status.shell == .bash)
            #expect(!status.isInstalled)

            // Install: script plus loader blocks in .bashrc and .bash_profile (which doesn't load .bashrc).
            let plan = try manager.installPlan(for: status, condition: .acceSSHSessionsOnly)
            #expect(plan.changes.map(\.path).sorted() == [".accessh/shell-integration/accessh.bash", ".bash_profile", ".bashrc"])
            try await manager.apply(plan)
            status = try await manager.inspect()
            #expect(status.isInstalled)
            #expect(status.installedScriptVersion == ShellIntegrationScripts.scriptVersion)
            #expect(Set(status.filesWithLoaderBlock) == [".bashrc", ".bash_profile"])
            #expect(try await manager.readFile(".bashrc.accessh-backup") == originalBashrc)
            let syntax = try await connection.execute("bash -n '\(base)/.bashrc' && bash -n '\(base)/.accessh/shell-integration/accessh.bash'")
            #expect(syntax.exitStatus == 0)

            // An older script on the server is offered as an update.
            _ = try await connection.execute("sed -i 's/Script version [0-9.]*\\./Script version 0.9./' '\(base)/.accessh/shell-integration/accessh.bash'")
            status = try await manager.inspect()
            #expect(status.installedScriptVersion == "0.9")
            #expect(status.isUpdateAvailable)
            let update = try manager.installPlan(for: status, condition: .acceSSHSessionsOnly)
            #expect(update.changes.filter { $0.kind != .unchanged }.map(\.path) == [".accessh/shell-integration/accessh.bash"])

            // A file edited after review blocks the whole plan.
            _ = try await connection.execute("echo '# edited meanwhile' >> '\(base)/.accessh/shell-integration/accessh.bash'")
            await #expect(throws: RemoteIntegrationError.fileChangedSinceReview(".accessh/shell-integration/accessh.bash")) {
                try await manager.apply(update)
            }
            status = try await manager.inspect()
            try await manager.apply(try manager.installPlan(for: status, condition: .acceSSHSessionsOnly))
            #expect(try await manager.inspect().isUpdateAvailable == false)

            // Remove: startup files return to their original text and the folder is gone.
            status = try await manager.inspect()
            try await manager.apply(try manager.removalPlan(for: status))
            #expect(try await manager.readFile(".bashrc") == originalBashrc)
            #expect(try await manager.readFile(".bash_profile") == originalProfile)
            let folder = try await connection.execute("[ -e '\(base)/.accessh' ] && echo present || echo gone")
            #expect(folder.outputText.trimmingCharacters(in: .whitespacesAndNewlines) == "gone")
        }
    }

    /// Read-only: the real installation in the home folder is detected.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ACCESSH_TEST_EXPECT_INTEGRATION"] == "1"))
    func detectsTheRealInstallation() async throws {
        let connection = try await LiveServer.connectAndAuthenticate()
        defer { connection.disconnect() }
        let status = try await RemoteShellIntegrationManager(connection: connection).inspect()
        #expect(status.shell == .bash)
        #expect(status.isInstalled)
        #expect(status.installedScriptVersion == ShellIntegrationScripts.scriptVersion)
        #expect(status.filesWithLoaderBlock == [".bashrc"])
        #expect(!status.isUpdateAvailable)
    }
}
