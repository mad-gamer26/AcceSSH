import SwiftUI
import AcceSSHCore

struct AppearanceSettingsView: View {
    @Environment(AppModel.self) private var model
    private let fonts = [AppearanceSettings().fontName, "Menlo", "Courier New"]

    var body: some View {
        @Bindable var settings = model.settings
        let appearance = $settings.appearance
        let accessibility = $settings.accessibility
        Form {
            Section(heading: "Colors") {
                Toggle("Match System Light and Dark", isOn: appearance.followsSystemAppearance)
                ChoicePicker(appearance.wrappedValue.followsSystemAppearance ? "Dark Theme" : "Theme", selection: appearance.darkThemeID, options: settings.library.themes.map { ChoiceOption($0.id, $0.name) })
                if appearance.wrappedValue.followsSystemAppearance {
                    ChoicePicker("Light Theme", selection: appearance.lightThemeID, options: settings.library.themes.map { ChoiceOption($0.id, $0.name) })
                }
            }
            Section(heading: "Text") {
                ChoicePicker("Font", selection: appearance.fontName, options: fonts.map { ChoiceOption($0, $0) })
                ValueStepper(title: "Font Size", value: appearance.fontSize, range: 8...40, step: 1) { "\(Int($0)) points" }
                Toggle("Scale with System Text Size", isOn: appearance.followsSystemTextSize)
                ChoicePicker("Weight", selection: appearance.fontWeight, options: TerminalFontWeight.allCases.map { ChoiceOption($0, $0.rawValue.capitalized) })
                ValueStepper(title: "Line Spacing", value: appearance.lineSpacing, range: 1...1.6, step: 0.1) {
                    String(format: "%.1f times", $0)
                }
                ValueStepper(title: "Character Spacing", value: appearance.characterSpacing, range: 0...4, step: 0.5) {
                    String(format: "%.1f points", $0)
                }
                Toggle("Underline Links", isOn: appearance.underlineHyperlinks)
            }
            Section(heading: "Cursor") {
                ChoicePicker("Shape", selection: appearance.cursorShape, options: [ChoiceOption(CursorShape.block, "Block"), ChoiceOption(CursorShape.underline, "Underline"), ChoiceOption(CursorShape.bar, "Bar")])
                Toggle("Make Cursor Easier to See", isOn: accessibility.enhancedCursorVisibility)
            }
            Section {
                Toggle("Always Use High Contrast", isOn: accessibility.forceHighContrast)
                Toggle("High Contrast with Increase Contrast", isOn: accessibility.followSystemIncreaseContrast)
                Toggle("Bold Terminal Text", isOn: accessibility.boldTerminalText)
                Toggle("Mark Colored Text", isOn: accessibility.differentiateWithoutColor)
            } header: {
                SectionHeader("Visibility")
            } footer: {
                FooterText("Mark Colored Text adds a dotted underline to colored output, so its meaning doesn’t depend on color.")
            }
        }
    }
}

struct TerminalBehaviorSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        let terminal = $settings.terminal
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Terminal Type")
                    TextField("xterm-256color", text: terminal.terminalType, axis: .vertical)
                        .lineLimit(1...3)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .accessibilityLabel("Terminal Type")
                }
                ValueStepper(title: "Scrollback", value: terminal.scrollbackLines.asDouble, range: 1_000...100_000, step: 1_000) {
                    "\(Int($0).formatted()) lines"
                }
                Toggle("Delete Key Sends DEL", isOn: terminal.backspaceSendsDelete)
            } footer: {
                FooterText("Terminal type is sent to the server as TERM when a session starts. Most servers expect xterm-256color.")
            }
            Section(heading: "Paste") {
                ChoicePicker("Confirm Before Pasting", selection: terminal.pasteConfirmation, options: [ChoiceOption(PasteConfirmation.whenMultiline, "Multiple lines or long text"), ChoiceOption(PasteConfirmation.always, "Always"), ChoiceOption(PasteConfirmation.never, "Only very long text")])
                Toggle("Bracketed Paste", isOn: terminal.allowBracketedPaste)
            }
            Section {
                Toggle("Allow Title Changes", isOn: terminal.allowTitleChanges)
                Toggle("Allow Notifications from Server", isOn: terminal.allowRemoteNotifications)
                ChoicePicker("Server Clipboard Access", selection: terminal.remoteClipboardWrite, options: [ChoiceOption(RemoteClipboardPolicy.ask, "Ask"), ChoiceOption(RemoteClipboardPolicy.allow, "Allow"), ChoiceOption(RemoteClipboardPolicy.deny, "Never")])
            } header: {
                SectionHeader("Server Requests")
            } footer: {
                FooterText("Programs on the server can ask to copy text to this device’s clipboard. They can never read your clipboard.")
            }
            Section {
                ChoicePicker("Keep Command History", selection: terminal.history.retention, options: [ChoiceOption(CommandHistorySettings.Retention.session, "For this session"), ChoiceOption(CommandHistorySettings.Retention.off, "Don’t keep")])
                Toggle("Skip Commands Starting with a Space", isOn: terminal.history.ignoreLeadingSpace)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Never Keep Commands Containing")
                    TextField("Words, separated by commas", text: Binding(
                        get: { settings.terminal.history.excludedSubstrings.joined(separator: ", ") },
                        set: { settings.terminal.history.excludedSubstrings = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
                    ), axis: .vertical)
                    .lineLimit(1...6)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .accessibilityLabel("Never Keep Commands Containing")
                }
            } header: {
                SectionHeader("Command History")
            } footer: {
                FooterText("This is AcceSSH’s own history for Up and Down Arrow in the Command field. Passwords typed at password prompts are never kept. Separate words with commas.")
            }
        }
    }
}

struct KeyboardSettingsView: View {
    @Environment(AppModel.self) private var model

    /// Choices for a three-finger swipe.
    static let swipeOptions: [ChoiceOption<KeyAction?>] = {
        var options: [ChoiceOption<KeyAction?>] = [ChoiceOption(nil, "Scroll the Terminal")]
        let keys: [(KeyChord, String)] = [
            (KeyChord(.up), "Up Arrow"), (KeyChord(.down), "Down Arrow"),
            (KeyChord(.left), "Left Arrow"), (KeyChord(.right), "Right Arrow"),
            (KeyChord(.pageUp), "Page Up"), (KeyChord(.pageDown), "Page Down"),
            (KeyChord(.home), "Home"), (KeyChord(.end), "End"),
            (KeyChord(.tab), "Tab"), (KeyChord(.tab, modifiers: .shift), "Shift Tab"),
            (KeyChord(.escape), "Escape"), (KeyChord(.enter), "Return"),
            (KeyChord(.text("c"), modifiers: .control), "Control C"),
            (KeyChord(.left, modifiers: .option), "Option Left Arrow (word left)"),
            (KeyChord(.right, modifiers: .option), "Option Right Arrow (word right)"),
        ]
        options += keys.map { ChoiceOption(KeyAction?.some(.key($0.0)), $0.1) }
        let commands: [AppCommand] = [.readNewOutput, .readCurrentLine, .readLastCommandOutput, .describeScreen,
                                      .repeatLastAnnouncement, .toggleAutomaticSpeech, .speakCursorPosition]
        options += commands.map { ChoiceOption(KeyAction?.some(.app($0)), $0.displayName) }
        return options
    }()

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                ChoicePicker("Default Input Mode", selection: Binding(
                    get: { settings.keyboard.defaultInputMode ?? .automatic },
                    set: { settings.keyboard.defaultInputMode = $0 }
                ), options: InputModePreference.allCases.map { ChoiceOption($0, $0.displayName) })
            } footer: {
                FooterText("Automatic uses Line Editing at the shell prompt and Direct Keys in full-screen programs such as nano and vim. Line Editing gives you a text field and sends the line when you press Return. Direct Keys sends every key straight to the server and announces every character. You can still switch during a session from Terminal Actions, and set a different mode for a host in its settings. Password prompts always use a secure text field.")
            }
            Section {
                ForEach(SwipeDirection.allCases, id: \.self) { direction in
                    ChoicePicker(direction.displayName, selection: Binding(
                        get: { settings.keyboard.effectiveGestures.threeFingerSwipes[direction] },
                        set: { action in
                            var gestures = settings.keyboard.effectiveGestures
                            gestures.threeFingerSwipes[direction] = action
                            settings.keyboard.gestures = gestures
                        }
                    ), options: Self.swipeOptions)
                }
                Button("Restore Arrow Keys") { settings.keyboard.gestures = nil }
            } header: {
                SectionHeader("Three-Finger Swipes in the Terminal")
            } footer: {
                FooterText("With VoiceOver focus in the terminal, a three-finger swipe sends the chosen key or runs the chosen command. Choose Scroll the Terminal to keep VoiceOver’s normal scrolling for that direction. If you reversed scrolling in VoiceOver settings, swap the choices to match.")
            }
            Section {
                Toggle("Option Key Acts as Meta", isOn: $settings.keyboard.optionSendsEscape)
            } footer: {
                FooterText("When on, Option plus a key sends Escape and the key, which shells and Emacs use for word movement. Turn it off to type special characters with Option.")
            }
            Section {
                Text("VoiceOver’s Quick Nav uses the arrow keys on a hardware keyboard. To send arrow keys to the server, turn Quick Nav off by pressing Left Arrow and Right Arrow together. You can also use the arrow buttons in the key bar.")
            } header: {
                SectionHeader("Arrow Keys and VoiceOver")
            }
        }
    }
}
