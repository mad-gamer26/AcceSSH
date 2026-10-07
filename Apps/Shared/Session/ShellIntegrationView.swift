import SwiftUI
import AcceSSHCore
import AcceSSHShellIntegration
import AcceSSHTransport

/// Shell integration for the current host: status, explanation, install, update, remove,
/// activation and troubleshooting. Every server change is shown in full and needs approval.
struct ShellIntegrationView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let session: TerminalSession

    @State private var status: RemoteIntegrationStatus?
    @State private var checking = false
    @State private var error: String?
    @State private var condition = ShellIntegrationInstaller.LoadCondition.acceSSHSessionsOnly
    @State private var review: PlanReview?

    struct PlanReview: Identifiable {
        enum Kind { case install, update, remove }
        let id = UUID()
        let kind: Kind
        let plan: ShellIntegrationInstaller.Plan
    }

    var body: some View {
        NavigationStack {
            Form {
                statusSection
                Section {
                    Text("Shell integration is a small script on the server that marks where each prompt, command and its output begin and end, and reports each command’s exit status and the current folder. AcceSSH uses these marks to read command output exactly and to announce failed commands. It only prints invisible codes to your own terminal; it sends nothing anywhere else and only loads in AcceSSH sessions unless you choose otherwise.")
                } header: {
                    SectionHeader("What It Does")
                }
                serverSection
                hostSection
                troubleshootingSection
            }
            .navigationTitle("Shell Integration")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task { await check() }
            .sheet(item: $review) { review in
                PlanReviewView(review: review) {
                    await apply(review)
                }
            }
        }
    }

    // MARK: Sections

    @ViewBuilder private var statusSection: some View {
        let state = session.shellIntegration
        Section(heading: "In This Session") {
            Text(state.summary)
            if state.status == .active || state.status == .newerProtocol {
                if let shell = state.shell { InfoRow("Shell", value: shell) }
                if let version = state.scriptVersion { InfoRow("Script Version", value: version) }
                InfoRow("Verified", value: state.isTokenVerified ? "Yes" : "No")
                InfoRow("Reports", value: state.capabilities.displayNames.joined(separator: ", "))
            }
            if let status, status.isInstalled, !state.isAuthoritative {
                Button("Activate Now") {
                    session.activateIntegrationNow()
                    Announcer.announce("Activating shell integration.")
                }
                .accessibilityHint("Loads the installed script in this session without changing any files.")
            }
        }
    }

    @ViewBuilder private var serverSection: some View {
        Section {
            if checking {
                ProgressView("Checking the server…")
            } else if let status {
                InfoRow("Login Shell", value: status.shell?.displayName ?? status.shellPath)
                InfoRow("Installed", value: status.installedScriptVersion.map { "Version \($0)" } ?? "No")
                if !status.filesWithLoaderBlock.isEmpty {
                    InfoRow("Loaded From", value: status.filesWithLoaderBlock.joined(separator: ", "))
                }
                if status.shell != nil {
                    ChoicePicker("Load", selection: $condition, options: [
                        ChoiceOption(.acceSSHSessionsOnly, "Only in AcceSSH sessions"),
                        ChoiceOption(.always, "In every interactive shell"),
                    ])
                    if !status.isInstalled {
                        Button("Install…") { makePlan(.install) }
                    } else if status.isUpdateAvailable {
                        Button("Update to Version \(ShellIntegrationScripts.scriptVersion)…") { makePlan(.update) }
                    } else {
                        Button("Reinstall or Change Loading…") { makePlan(.update) }
                    }
                    if status.installedScriptVersion != nil || !status.filesWithLoaderBlock.isEmpty {
                        Button("Remove…", role: .destructive) { makePlan(.remove) }
                            .foregroundStyle(Color.accessibleDestructive)
                    }
                }
                Button("Check Again") { Task { await check() } }
            } else if session.integrationManager() == nil {
                Text("Connect to the server to check, install or remove shell integration.")
            }
            if let error {
                Text(error).foregroundStyle(Color.red)
            }
        } header: {
            SectionHeader("On This Server")
        } footer: {
            FooterText("Before anything changes you’ll see every line that will be added or removed. AcceSSH keeps a backup of each startup file it changes, ending in .accessh-backup.")
        }
    }

    @ViewBuilder private var hostSection: some View {
        Section {
            ChoicePicker("Use Shell Integration", selection: Binding(
                get: { model.hosts.hosts.first { $0.id == session.host.id }?.shellIntegration ?? session.host.shellIntegration },
                set: { preference in
                    guard var host = model.hosts.hosts.first(where: { $0.id == session.host.id }) else { return }
                    host.shellIntegration = preference
                    model.hosts.save(host)
                }
            ), options: [
                ChoiceOption(.automatic, "When the server provides it"),
                ChoiceOption(.activateOnConnect, "Activate on connect"),
                ChoiceOption(.disabled, "Off"),
            ])
        } header: {
            SectionHeader("For This Host")
        } footer: {
            FooterText("Activate on connect loads the installed script each time you connect, without changing startup files. Off ignores shell integration for this host. Changes apply the next time you connect.")
        }
    }

    @ViewBuilder private var troubleshootingSection: some View {
        let tips = troubleshootingTips
        if !tips.isEmpty {
            Section(heading: "Troubleshooting") {
                ForEach(tips, id: \.self) { Text($0) }
            }
        }
    }

    private var troubleshootingTips: [String] {
        var tips: [String] = []
        let state = session.shellIntegration
        if let status {
            if status.shell == nil {
                tips.append("Your login shell, \(status.shellPath), isn’t supported. AcceSSH has integration for bash, zsh and fish; you can still use AcceSSH normally without it.")
            }
            if status.isInstalled, state.status == .notDetected {
                tips.append("The script is installed but isn’t running in this session. If you just installed it, choose Activate Now or reconnect. If it’s still inactive after reconnecting, the server may not pass the LC_TERMINAL variable: set Load to “In every interactive shell”, or set this host to Activate on connect.")
            }
            if status.isUpdateAvailable {
                tips.append("A newer script is available. Updating replaces only the script file.")
            }
        }
        if state.status == .marksOnly {
            tips.append("Another terminal’s shell integration is sending prompt marks. Command boundaries work, but command text and the current folder may be missing until AcceSSH’s script is installed.")
        }
        if state.status == .active, !state.isTokenVerified {
            tips.append("Integration is active but not verified: the script didn’t receive AcceSSH’s session token, usually because the server doesn’t pass LC_ variables. It still works.")
        }
        if state.status == .newerProtocol {
            tips.append("The script on the server is newer than this version of AcceSSH. Update AcceSSH for full support.")
        }
        if state.status == .disabled {
            tips.append("Shell integration is turned off for this host.")
        }
        return tips
    }

    // MARK: Actions

    private func check() async {
        guard let manager = session.integrationManager() else { return }
        checking = true
        defer { checking = false }
        do {
            status = try await manager.inspect()
            error = nil
            if let status, status.filesWithLoaderBlock.contains(where: { (status.files[$0] ?? nil)?.contains("LC_TERMINAL") == false }) {
                condition = .always
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func makePlan(_ kind: PlanReview.Kind) {
        guard let manager = session.integrationManager(), let status else { return }
        do {
            let plan = kind == .remove ? try manager.removalPlan(for: status) : try manager.installPlan(for: status, condition: condition)
            if plan.isNoOp {
                Announcer.announce("Nothing to change. Shell integration is already set up this way.")
                return
            }
            review = PlanReview(kind: kind, plan: plan)
        } catch {
            self.error = error.localizedDescription
            Announcer.announce(error.localizedDescription)
        }
    }

    private func apply(_ review: PlanReview) async {
        guard let manager = session.integrationManager() else { return }
        do {
            try await manager.apply(review.plan)
            self.review = nil
            await check()
            switch review.kind {
            case .install, .update:
                Announcer.announce("Shell integration installed. Choose Activate Now, or reconnect, to start using it.")
            case .remove:
                Announcer.announce("Shell integration removed. It stops when you reconnect.")
            }
        } catch {
            self.review = nil
            self.error = error.localizedDescription
            Announcer.announce(error.localizedDescription)
        }
    }
}

/// Shows every change a plan makes, line by line, and applies it only on approval.
private struct PlanReviewView: View {
    @Environment(\.dismiss) private var dismiss
    let review: ShellIntegrationView.PlanReview
    let apply: () async -> Void
    @State private var applying = false

    private var title: String {
        switch review.kind {
        case .install: "Review Installation"
        case .update: "Review Update"
        case .remove: "Review Removal"
        }
    }

    private var actionTitle: String {
        switch review.kind {
        case .install: "Install"
        case .update: "Update"
        case .remove: "Remove"
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("These changes will be made on the server. Expand a file to hear or read every line.")
                }
                ForEach(review.plan.changes.filter { $0.kind != .unchanged }) { change in
                    Section {
                        Text(change.summary)
                        if change.kind == .modify, change.originalContents?.isEmpty == false, change.newContents.isEmpty == false,
                           !change.path.hasPrefix(".accessh") {
                            Text("A backup is kept as \(change.path).accessh-backup.")
                        }
                        lines("Lines Added", change.kind == .create ? Self.fileLines(change.newContents) : change.addedLines)
                        lines("Lines Removed", change.newContents.isEmpty ? Self.fileLines(change.originalContents ?? "") : change.removedLines)
                    } header: {
                        SectionHeader(change.path)
                            .accessibilityLabel("File \(change.path)")
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if applying {
                        ProgressView().accessibilityLabel("Applying changes")
                    } else {
                        Button(actionTitle) {
                            applying = true
                            Task {
                                await apply()
                                applying = false
                            }
                        }
                    }
                }
            }
        }
        .interactiveDismissDisabled(applying)
    }

    /// A whole file's lines, without the empty piece after its final newline.
    static func fileLines(_ text: String) -> [String] {
        let pieces = text.components(separatedBy: "\n")
        return pieces.last == "" ? Array(pieces.dropLast()) : pieces
    }

    /// Lists changed lines exactly as counted in the summary (blank lines included).
    @ViewBuilder private func lines(_ title: String, _ shown: [String]) -> some View {
        if !shown.isEmpty {
            DisclosureGroup("\(title) (\(shown.count))") {
                ForEach(Array(shown.enumerated()), id: \.offset) { index, line in
                    Text(line.isEmpty ? "Blank line" : line)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(Color.primary)
                        .textSelection(.enabled)
                        // "Line 3 of 9" followed by the code, so VoiceOver users know where they are.
                        .accessibilityLabel("Line \(index + 1) of \(shown.count)")
                        .accessibilityValue(line.isEmpty ? "blank" : line)
                }
            }
        }
    }
}
