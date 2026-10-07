import SwiftUI
import AcceSSHCore

/// Edits the key bar above the keyboard: reorder, remove and add buttons.
struct ToolbarSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var adding = false

    var body: some View {
        @Bindable var settings = model.settings
        let items = settings.toolbar.items
        List {
            Section {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    VStack(alignment: .leading) {
                        Text(item.accessibilityLabel)
                        if item.title != item.accessibilityLabel {
                            Text("Shown as “\(item.title)”").font(.footnote)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityValue("Button \(index + 1) of \(items.count)")
                    .accessibilityAction(named: "Move Earlier") { move(from: index, to: index - 1) }
                    .accessibilityAction(named: "Move Later") { move(from: index, to: index + 1) }
                    .accessibilityAction(named: "Remove") { settings.toolbar.items.remove(at: index) }
                }
                .onMove { settings.toolbar.items.move(fromOffsets: $0, toOffset: $1) }
                .onDelete { settings.toolbar.items.remove(atOffsets: $0) }
            } header: {
                SectionHeader("Buttons")
            } footer: {
                FooterText("With VoiceOver, swipe up or down on a button and choose Move Earlier, Move Later or Remove.")
            }
            Section {
                Button("Add Button…") { adding = true }
                Button("Restore Standard Buttons") { settings.toolbar.items = ToolbarProfile.standard.items }
            }
        }
        .toolbar { EditButton() }
        .sheet(isPresented: $adding) {
            AddToolbarItemView { settings.toolbar.items.append($0) }
        }
    }

    private func move(from: Int, to: Int) {
        var items = model.settings.toolbar.items
        guard items.indices.contains(from), items.indices.contains(to) else { return }
        items.swapAt(from, to)
        model.settings.toolbar.items = items
        Announcer.announce("Moved to position \(to + 1)")
    }
}

private struct AddToolbarItemView: View {
    @Environment(\.dismiss) private var dismiss
    let onAdd: (AcceSSHCore.ToolbarItem) -> Void
    @State private var customLabel = ""
    @State private var customText = ""
    @State private var pressReturn = true

    private static let keys: [AcceSSHCore.ToolbarItem] = [
        .key(KeyChord(.escape), title: "Esc", label: "Escape"),
        .key(KeyChord(.tab), title: "Tab"),
        .key(KeyChord(.tab, modifiers: .shift), title: "⇧Tab", label: "Shift Tab"),
        AcceSSHCore.ToolbarItem(action: .latchModifier(.control), title: "Ctrl", accessibilityLabel: "Control",
                    accessibilityHint: "Applies Control to the next key you type."),
        AcceSSHCore.ToolbarItem(action: .latchModifier(.option), title: "Alt", accessibilityLabel: "Option",
                    accessibilityHint: "Applies Option, also called Alt or Meta, to the next key you type."),
        .key(KeyChord(.up), title: "Up", symbol: "arrow.up"),
        .key(KeyChord(.down), title: "Down", symbol: "arrow.down"),
        .key(KeyChord(.left), title: "Left", symbol: "arrow.left"),
        .key(KeyChord(.right), title: "Right", symbol: "arrow.right"),
        .key(KeyChord(.home), title: "Home"),
        .key(KeyChord(.end), title: "End"),
        .key(KeyChord(.pageUp), title: "PgUp", label: "Page Up"),
        .key(KeyChord(.pageDown), title: "PgDn", label: "Page Down"),
        .key(KeyChord(.insert), title: "Ins", label: "Insert"),
        .key(KeyChord(.delete), title: "Del", label: "Forward Delete"),
    ] + (1...12).map { .key(KeyChord(.function($0)), title: "F\($0)") }
      + ["a", "c", "d", "e", "l", "r", "u", "w", "x", "z"].map {
          .key(KeyChord(.text($0), modifiers: .control), title: "^\($0.uppercased())", label: "Control \($0.uppercased())")
      }

    private static let commands: [AppCommand] = [
        .readNewOutput, .readCurrentLine, .readLastCommand, .readLastCommandOutput, .describeScreen,
        .toggleAutomaticSpeech, .repeatLastAnnouncement, .speakCursorPosition, .copyLastCommandOutput, .paste,
        .clearScreen, .clearScrollback,
    ]

    var body: some View {
        NavigationStack {
            List {
                Section(heading: "Keys") {
                    ForEach(Self.keys) { item in
                        Button(item.accessibilityLabel) { add(item) }
                    }
                }
                Section(heading: "AcceSSH Commands") {
                    ForEach(Self.commands, id: \.self) { command in
                        Button(command.displayName) {
                            add(AcceSSHCore.ToolbarItem(action: .app(command), title: command.displayName, accessibilityLabel: command.displayName))
                        }
                    }
                }
                Section {
                    TextField("Button Name", text: $customLabel)
                    TextField("Text to Send", text: $customText)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Toggle("Press Return After", isOn: $pressReturn)
                    Button("Add Custom Button") {
                        add(AcceSSHCore.ToolbarItem(action: .command(customText, pressReturn: pressReturn),
                                        title: customLabel, accessibilityLabel: customLabel))
                    }
                    .disabled(customLabel.isEmpty || customText.isEmpty)
                } header: {
                    SectionHeader("Custom Command")
                } footer: {
                    FooterText("For example, name it “Disk Usage” and send “df -h”.")
                }
            }
            .navigationTitle("Add Button")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }

    private func add(_ item: AcceSSHCore.ToolbarItem) {
        var copy = item
        copy.id = UUID()
        onAdd(copy)
        dismiss()
    }
}
