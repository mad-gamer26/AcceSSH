import SwiftUI
import AcceSSHCore

/// Settings root. Every category applies to open sessions immediately.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section(heading: "Accessibility") {
                    link("VoiceOver and Speech", "speaker.wave.2", VoiceOverSettingsView())
                    link("Announcements", "bell.badge", AnnouncementSettingsView())
                }
                Section(heading: "Terminal") {
                    link("Appearance", "textformat.size", AppearanceSettingsView())
                    link("Terminal", "terminal", TerminalBehaviorSettingsView())
                    link("Keyboard", "keyboard", KeyboardSettingsView())
                    link("Key Bar", "rectangle.split.3x1", ToolbarSettingsView())
                    link("Bell", "bell", BellSettingsView())
                }
                Section(heading: "Security") {
                    link("SSH Keys", "key", KeysSettingsView())
                    link("Trusted Host Keys", "checkmark.shield", KnownHostsSettingsView())
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private func link<Destination: View>(_ title: String, _ symbol: String, _ destination: Destination) -> some View {
        NavigationLink {
            destination.navigationTitle(title)
        } label: {
            Label(title, systemImage: symbol)
        }
    }
}

/// Section header text at full contrast (the system default is a lighter gray).
struct SectionHeader: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View { Text(title).foregroundStyle(Color.primary) }
}

/// Section footer text at full contrast.
struct FooterText: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).font(.footnote).foregroundStyle(Color.primary) }
}

@MainActor
extension Section where Parent == SectionHeader, Footer == EmptyView, Content: View {
    /// A section whose header uses full-contrast text.
    init(heading: String, @ViewBuilder content: () -> Content) {
        self.init(content: content, header: { SectionHeader(heading) })
    }
}

/// A label and value at full contrast (LabeledContent draws the value in light gray).
/// VoiceOver reads it as one element: "Title, value".
struct InfoRow: View {
    let title: String
    let value: String
    init(_ title: String, value: String) {
        self.title = title
        self.value = value
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                Spacer()
                Text(value).multilineTextAlignment(.trailing)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(value)
            }
        }
        .foregroundStyle(Color.primary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(value)
    }
}

/// A stepper whose VoiceOver value includes the unit.
struct ValueStepper: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String

    var body: some View {
        Stepper(value: $value, in: range, step: step) {
            // Stacks the value under the title when large text doesn't fit on one line.
            ViewThatFits(in: .horizontal) {
                HStack {
                    Text(title)
                    Spacer()
                    Text(format(value)).monospacedDigit()
                }
                VStack(alignment: .leading) {
                    Text(title)
                    Text(format(value)).monospacedDigit()
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(format(value))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = min(range.upperBound, value + step)
            case .decrement: value = max(range.lowerBound, value - step)
            @unknown default: break
            }
        }
    }
}

extension Binding where Value == Int {
    /// Bridges an Int setting to ``ValueStepper``.
    var asDouble: Binding<Double> {
        Binding<Double>(get: { Double(wrappedValue) }, set: { wrappedValue = Int($0.rounded()) })
    }
}

/// One choice in a ``ChoicePicker``.
struct ChoiceOption<Value: Hashable> {
    let value: Value
    let name: String
    init(_ value: Value, _ name: String) {
        self.value = value
        self.name = name
    }
}

/// A picker whose row shows the current choice at full contrast (system pickers draw it in
/// light gray) and whose choices open on their own page, with the selection reported to VoiceOver.
struct ChoicePicker<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [ChoiceOption<Value>]

    init(_ title: String, selection: Binding<Value>, options: [ChoiceOption<Value>]) {
        self.title = title
        _selection = selection
        self.options = options
    }

    private var currentName: String { options.first { $0.value == selection }?.name ?? "" }

    var body: some View {
        NavigationLink {
            ChoiceList(title: title, selection: $selection, options: options)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(currentName).font(.subheadline).foregroundStyle(Color.primary)
            }
        }
        .accessibilityLabel(title)
        .accessibilityValue(currentName)
    }
}

private struct ChoiceList<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [ChoiceOption<Value>]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                let isSelected = option.value == selection
                Button {
                    selection = option.value
                    dismiss()
                } label: {
                    HStack {
                        Text(option.name).foregroundStyle(Color.primary)
                        Spacer()
                        if isSelected {
                            Image(systemName: "checkmark").foregroundStyle(Color.accessibleAccent).accessibilityHidden(true)
                        }
                    }
                }
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .navigationTitle(title)
    }
}
