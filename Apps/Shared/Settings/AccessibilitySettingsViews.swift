import SwiftUI
import AcceSSHCore

struct VoiceOverSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        let voiceOver = $settings.accessibility.voiceOver
        Form {
            Section {
                ChoicePicker("Automatic Reading", selection: voiceOver.automaticReading, options: AutomaticReadingMode.allCases.map { ChoiceOption($0, $0.displayName) })
                ChoicePicker("Prompts", selection: voiceOver.promptReading, options: [ChoiceOption(PromptReading.fullText, "Read the prompt"), ChoiceOption(PromptReading.announceOnly, "Say a short phrase"), ChoiceOption(PromptReading.off, "Don’t announce")])
                if voiceOver.wrappedValue.promptReading == .announceOnly {
                    TextField("Prompt Phrase", text: voiceOver.promptPhrase)
                }
                ChoicePicker("Full-Screen Programs", selection: voiceOver.alternateScreenReading, options: [ChoiceOption(AlternateScreenReading.highlightAndCursorLine, "Highlighted item and cursor line"), ChoiceOption(AlternateScreenReading.changedLines, "Every changed line"), ChoiceOption(AlternateScreenReading.off, "Nothing automatically")])
            } header: {
                SectionHeader("What Is Spoken")
            } footer: {
                FooterText("Full-screen programs are ones like nano, vim, htop and menus. Everything that isn’t spoken is kept for Read New Output.")
            }

            Section {
                ValueStepper(title: "Wait for Quiet", value: voiceOver.coalescingInterval, range: 0.1...2, step: 0.1) {
                    String(format: "%.1f seconds", $0)
                }
                ValueStepper(title: "Longest Wait", value: voiceOver.maximumLatency, range: 0.5...5, step: 0.5) {
                    String(format: "%.1f seconds", $0)
                }
                ValueStepper(title: "Lines at Once", value: voiceOver.maximumLinesPerAnnouncement.asDouble, range: 1...50, step: 1) {
                    "\(Int($0)) lines"
                }
                ChoicePicker("When There’s More Output", selection: voiceOver.overflowStrategy, options: [ChoiceOption(OutputOverflowStrategy.speakLastLines, "Read the last lines"), ChoiceOption(OutputOverflowStrategy.speakFirstLines, "Read the first lines"), ChoiceOption(OutputOverflowStrategy.summarize, "Just say how many lines")])
            } header: {
                SectionHeader("Fast Output")
            } footer: {
                FooterText("Output is spoken once it has been quiet for the wait time, or after the longest wait during a continuous stream, so VoiceOver isn’t overwhelmed.")
            }

            Section(heading: "Typing") {
                Toggle("Don’t Repeat Typed Commands", isOn: voiceOver.suppressCommandEcho)
                Toggle("Speak Completions and History", isOn: voiceOver.speakInsertedCompletions)
                Toggle("Speak Deleted Characters", isOn: voiceOver.speakDeletedCharacters)
            }

            Section(heading: "Text Cleanup") {
                Toggle("Skip Line-Drawing Characters", isOn: voiceOver.skipBoxDrawingCharacters)
                Toggle("Skip Repeated Symbols", isOn: voiceOver.collapseRepeatedSymbols)
                Toggle("Wait for Complete Screen Updates", isOn: voiceOver.respectSynchronizedOutput)
            }

            Section {
                Toggle("Announce Successful Commands", isOn: voiceOver.announceSuccessfulCommands)
                Toggle("Announce Failed Commands", isOn: voiceOver.announceFailedCommands)
                Toggle("Include Exit Status", isOn: voiceOver.includeExitStatus)
                Toggle("Include Command Name", isOn: voiceOver.includeCommandInCompletion)
                ChoicePicker("Announce Long Commands", selection: voiceOver.longRunningCommandThreshold,
                             options: [ChoiceOption(TimeInterval?.none, "Never")] + [5.0, 10, 30, 60, 300].map { seconds in
                                 ChoiceOption(TimeInterval?.some(seconds),
                                              seconds < 60 ? "After \(Int(seconds)) seconds" : "After \(Int(seconds / 60)) minute\(seconds == 60 ? "" : "s")")
                             })
            } header: {
                SectionHeader("Command Completion")
            } footer: {
                FooterText("Exact command boundaries and exit statuses need shell integration. Without it, AcceSSH detects prompts and can’t report exit status.")
            }
        }
    }
}

struct AnnouncementSettingsView: View {
    @Environment(AppModel.self) private var model
    private let categories: [AnnouncementCategory] = [
        .connection, .hostKey, .commandCompletion, .commandFailure, .remoteNotifications, .shellIntegration,
    ]

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                ForEach(categories, id: \.self) { category in
                    Toggle(category.displayName, isOn: Binding(
                        get: { settings.accessibility.voiceOver.enabledAnnouncements.contains(category) },
                        set: { enabled in
                            if enabled {
                                settings.accessibility.voiceOver.enabledAnnouncements.insert(category)
                            } else {
                                settings.accessibility.voiceOver.enabledAnnouncements.remove(category)
                            }
                        }
                    ))
                }
            } footer: {
                FooterText("Announcements are queued behind what VoiceOver is already saying, except host key warnings and connection failures.")
            }
        }
    }
}
