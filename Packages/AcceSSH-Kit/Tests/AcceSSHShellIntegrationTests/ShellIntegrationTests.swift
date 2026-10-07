import Foundation
import Testing
@testable import AcceSSHShellIntegration

@Suite("Shell integration protocol")
struct ProtocolTests {
    @Test func decodesFinalTermMarks() {
        #expect(ShellIntegrationDecoder.decode(oscCode: 133, payload: "A")?.0 == .promptStarted(.initial))
        #expect(ShellIntegrationDecoder.decode(oscCode: 133, payload: "A;k=s")?.0 == .promptStarted(.secondary))
        #expect(ShellIntegrationDecoder.decode(oscCode: 133, payload: "D;127")?.0 == .commandFinished(exitStatus: 127))
        #expect(ShellIntegrationDecoder.decode(oscCode: 133, payload: "D")?.0 == .commandFinished(exitStatus: nil))
        #expect(ShellIntegrationDecoder.decode(oscCode: 133, payload: "Z") == nil)
    }

    @Test func decodesAcceSSHMessages() throws {
        let hello = try #require(ShellIntegrationDecoder.decode(
            oscCode: 6973, payload: "hello;v=1;shell=bash;sv=1.0.0;caps=prompt,exit,cwd,bogus;host=h%3Bx;token="
        ))
        guard case let .hello(info) = hello.0 else { Issue.record("not hello"); return }
        #expect(info.protocolVersion == 1)
        #expect(info.shell == "bash")
        #expect(info.capabilities == [.prompts, .exitStatus, .workingDirectory])
        #expect(info.hostname == "h;x")
        #expect(info.token == nil)
        #expect(hello.1 == .acceSSH)

        #expect(ShellIntegrationDecoder.decode(oscCode: 6973, payload: "command;cmd=a%3Bb%0Ac")?.0 == .commandLine("a;b\nc"))
        #expect(ShellIntegrationDecoder.decode(oscCode: 6973, payload: "notify;body=Done;title=Build")?.0
            == .notification(title: "Build", body: "Done", urgency: .normal))
        #expect(ShellIntegrationDecoder.decode(oscCode: 6973, payload: "later-feature;x=1")?.0 == .unknown(event: "later-feature"))
    }

    @Test func rejectsOversizedPayloads() {
        let huge = String(repeating: "x", count: ShellIntegrationProtocol.maximumPayloadLength + 1)
        #expect(ShellIntegrationDecoder.decode(oscCode: 6973, payload: Substring("command;cmd=" + huge)) == nil)
    }

    @Test func percentCodingRoundTrips() {
        let original = "a%b;c=d\n\u{1B}é 中"
        let encoded = ShellIntegrationCoding.percentEncode(original)
        #expect(!encoded.contains(";"))
        #expect(!encoded.contains("\n"))
        #expect(ShellIntegrationCoding.percentDecode(encoded) == original)
        #expect(ShellIntegrationCoding.percentDecode("100%zz") == "100%zz")
    }

    @Test func versionComparison() {
        #expect(ShellIntegrationScripts.compareVersions("1.0.0", "1.0.1") == -1)
        #expect(ShellIntegrationScripts.compareVersions("1.10", "1.9") == 1)
        #expect(ShellIntegrationScripts.compareVersions("2", "2.0.0") == 0)
    }

    @Test func scriptsAreBundledWithMatchingVersions() throws {
        for shell in ShellKind.allCases {
            let script = try ShellIntegrationScripts.script(for: shell)
            #expect(script.contains("Script version \(ShellIntegrationScripts.scriptVersion)."))
            #expect(script.contains("6973;hello;v=\(ShellIntegrationProtocol.version)"))
        }
    }

    @Test func shellDetection() {
        #expect(ShellKind(shellPath: "/usr/bin/zsh") == .zsh)
        #expect(ShellKind(shellPath: "-bash") == .bash)
        #expect(ShellKind(shellPath: "/opt/homebrew/bin/fish") == .fish)
        #expect(ShellKind(shellPath: "/bin/tcsh") == nil)
    }
}

@Suite("Shell integration installer")
struct InstallerTests {
    @Test func installAppendsDelimitedBlockAndIsIdempotent() throws {
        let rc = "export EDITOR=vim\nalias ll='ls -l'"
        let plan = try ShellIntegrationInstaller.installPlan(
            shell: .zsh, condition: .acceSSHSessionsOnly,
            existingFiles: [".zshrc": rc]
        )
        let rcChange = try #require(plan.changes.first { $0.path == ".zshrc" })
        #expect(rcChange.kind == .modify)
        #expect(rcChange.newContents.hasPrefix(rc + "\n\n" + ShellIntegrationInstaller.beginMarker))
        #expect(rcChange.removedLines.isEmpty)
        #expect(rcChange.summary.hasPrefix("Modify .zshrc: add"))
        let scriptChange = try #require(plan.changes.first { $0.path == ShellKind.zsh.remoteScriptPath })
        #expect(scriptChange.kind == .create)

        // Running the plan again on the result changes nothing.
        let again = try ShellIntegrationInstaller.installPlan(
            shell: .zsh, condition: .acceSSHSessionsOnly,
            existingFiles: [".zshrc": rcChange.newContents, ShellKind.zsh.remoteScriptPath: scriptChange.newContents]
        )
        #expect(again.isNoOp)
    }

    @Test func updateReplacesOnlyTheBlock() throws {
        let block = ShellIntegrationInstaller.loaderBlock(for: .bash, condition: .acceSSHSessionsOnly)
        let rc = "before\n\n\(block)\nafter\n"
        let updated = try ShellIntegrationInstaller.applyingBlock(
            ShellIntegrationInstaller.loaderBlock(for: .bash, condition: .always), to: rc, file: ".bashrc"
        )
        #expect(updated.hasPrefix("before\n\n"))
        #expect(updated.hasSuffix("after\n"))
        #expect(!updated.contains("LC_TERMINAL"))
    }

    @Test func removalRestoresOriginal() throws {
        let original = "export PATH=$HOME/bin:$PATH\n"
        let installed = try ShellIntegrationInstaller.applyingBlock(
            ShellIntegrationInstaller.loaderBlock(for: .bash, condition: .always), to: original, file: ".bashrc"
        )
        #expect(try ShellIntegrationInstaller.removingBlock(from: installed, file: ".bashrc") == original)
    }

    @Test func removalSummariesDescribeDeletion() throws {
        let installed = try ShellIntegrationInstaller.applyingBlock(
            ShellIntegrationInstaller.loaderBlock(for: .bash, condition: .always), to: "x\n", file: ".bashrc")
        let plan = try ShellIntegrationInstaller.removalPlan(
            shell: .bash, existingFiles: [".bashrc": installed, ShellKind.bash.remoteScriptPath: "script\n"])
        let script = try #require(plan.changes.first { $0.path == ShellKind.bash.remoteScriptPath })
        #expect(script.summary == "Delete \(ShellKind.bash.remoteScriptPath)")
        let rc = try #require(plan.changes.first { $0.path == ".bashrc" })
        // The block plus the blank separator line before it.
        #expect(rc.removedLines.count == 9)
        #expect(rc.summary == "Modify .bashrc: remove 9 lines")
    }

    @Test func damagedBlockIsRefused() {
        let damaged = "x\n\(ShellIntegrationInstaller.beginMarker)\nsource something\n"
        #expect(throws: ShellIntegrationError.damagedBlock(file: ".zshrc")) {
            try ShellIntegrationInstaller.applyingBlock("new", to: damaged, file: ".zshrc")
        }
    }

    @Test func bashProfileGetsBlockOnlyWhenItSkipsBashrc() throws {
        let sourcing = try ShellIntegrationInstaller.installPlan(
            shell: .bash, condition: .always,
            existingFiles: [".bashrc": "", ".bash_profile": "[ -f ~/.bashrc ] && . ~/.bashrc\n"]
        )
        #expect(!sourcing.changes.contains { $0.path == ".bash_profile" })

        let standalone = try ShellIntegrationInstaller.installPlan(
            shell: .bash, condition: .always, existingFiles: [".bash_profile": "export X=1\n"]
        )
        #expect(standalone.changes.contains { $0.path == ".bash_profile" && $0.kind == .modify })
        #expect(standalone.changes.contains { $0.path == ".bashrc" && $0.kind == .create })
    }

    @Test func loaderBlocksAreValidShellSyntax() throws {
        for (shell, binary) in [(ShellKind.bash, "/bin/bash"), (.zsh, "/bin/zsh")] {
            for condition in ShellIntegrationInstaller.LoadCondition.allCases {
                let block = ShellIntegrationInstaller.loaderBlock(for: shell, condition: condition)
                #if os(macOS)
                let process = Process()
                process.executableURL = URL(fileURLWithPath: binary)
                process.arguments = ["-n", "-c", block]
                try process.run()
                process.waitUntilExit()
                #expect(process.terminationStatus == 0, "\(shell) \(condition) block has a syntax error")
                #endif
            }
        }
    }
}
