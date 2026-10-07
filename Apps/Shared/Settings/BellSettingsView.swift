import SwiftUI
import UniformTypeIdentifiers
import AcceSSHCore

/// Chooses and edits the terminal bell response.
struct BellSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var importingSound = false
    @State private var importError: String?
    @State private var deletingSound: String?

    private enum SoundChoice: String, CaseIterable, Identifiable {
        case none, tick, classic, twoNote, alarm, system
        var id: String { rawValue }

        var name: String {
            switch self {
            case .none: "None"
            case .tick: "Soft tick"
            case .classic: "Classic beep"
            case .twoNote: "Two notes"
            case .alarm: "Alarm"
            case .system: "System sound"
            }
        }

        var source: SoundSource {
            switch self {
            case .none: .none
            case .tick: .tone(ToneSpec(frequency: 1_320, duration: 0.04))
            case .classic: .tone(ToneSpec(frequency: 880, duration: 0.12, waveform: .square))
            case .twoNote: .tone(ToneSpec(frequency: 660, duration: 0.08, waveform: .triangle, secondFrequency: 990))
            case .alarm: .tone(ToneSpec(frequency: 988, duration: 0.15, waveform: .square, secondFrequency: 1_319))
            case .system: .systemAlert
            }
        }

        static func matching(_ source: SoundSource) -> SoundChoice {
            allCases.first { $0.source == source } ?? (source == .none ? .none : .classic)
        }
    }

    private enum HapticChoice: String, CaseIterable, Identifiable {
        case none, light, medium, heavy, success, warning, error, doubleTap, longBuzz
        var id: String { rawValue }

        var name: String {
            switch self {
            case .none: "None"
            case .light: "Light tap"
            case .medium: "Medium tap"
            case .heavy: "Strong tap"
            case .success: "Success"
            case .warning: "Warning"
            case .error: "Error"
            case .doubleTap: "Double tap"
            case .longBuzz: "Long buzz"
            }
        }

        var style: HapticStyle {
            switch self {
            case .none: .none
            case .light: .light
            case .medium: .medium
            case .heavy: .heavy
            case .success: .success
            case .warning: .warning
            case .error: .error
            case .doubleTap: .custom(.doubleTap)
            case .longBuzz: .custom(.longBuzz)
            }
        }

        static func matching(_ style: HapticStyle) -> HapticChoice {
            allCases.first { $0.style == style } ?? .medium
        }
    }

    var body: some View {
        @Bindable var settings = model.settings
        let profile = settings.bellProfile(id: settings.defaultBellID) ?? .default
        let binding = Binding<BellProfile>(get: { settings.bellProfile(id: settings.defaultBellID) ?? .default },
                                           set: { settings.updateBell($0) })
        Form {
            Section {
                ChoicePicker("Bell Style", selection: $settings.defaultBellID, options: settings.library.bell.map { ChoiceOption($0.id, $0.name) })
                Button("Test Bell") { BellPlayer.ring(profile: profile, speech: nil, preview: true) }
            } footer: {
                FooterText("Programs ring the bell to get your attention, for example when tab completion has no match. Changes below adjust the selected style.")
            }
            Section {
                ChoicePicker("Sound", selection: binding.sound, options: soundOptions(current: profile.sound))
                if profile.sound != .none {
                    ValueStepper(title: "Volume", value: binding.volume, range: 0.1...1, step: 0.1) { "\(Int(($0 * 100).rounded())) percent" }
                }
                Button("Import Sound from Files…") { importingSound = true }
                if let importError {
                    Text(importError).foregroundStyle(Color.red)
                }
            } header: {
                SectionHeader("Sound")
            } footer: {
                FooterText("Use your own WAV, AIFF, CAF, MP3 or M4A file, up to \(Int(SoundLibrary.maximumDuration)) seconds. A copy is kept in AcceSSH.")
            }
            if !model.sounds.sounds.isEmpty {
                Section(heading: "Your Sounds") {
                    ForEach(model.sounds.sounds, id: \.self) { fileName in
                        Button {
                            SoundFilePlayer.play(fileName: fileName, volume: profile.volume)
                        } label: {
                            Text(SoundLibrary.displayName(fileName)).foregroundStyle(Color.primary)
                        }
                        .accessibilityHint("Plays the sound.")
                        .accessibilityAction(named: "Use for Bell") { binding.wrappedValue.sound = .custom(fileName: fileName) }
                        .accessibilityAction(named: "Delete") { deletingSound = fileName }
                        .swipeActions {
                            Button("Delete", role: .destructive) { deletingSound = fileName }
                            Button("Use for Bell") { binding.wrappedValue.sound = .custom(fileName: fileName) }
                        }
                    }
                }
            }
            Section {
                ChoicePicker("Haptic", selection: Binding(
                    get: { HapticChoice.matching(binding.wrappedValue.haptic) },
                    set: { binding.wrappedValue.haptic = $0.style }
                ), options: HapticChoice.allCases.map { ChoiceOption($0, $0.name) })
            } header: {
                SectionHeader("Haptic")
            } footer: {
                FooterText(HapticPlayer.capabilityDescription)
            }
            Section(heading: "Speech") {
                Toggle("Speak a Phrase", isOn: Binding(
                    get: { binding.wrappedValue.spokenPhrase != nil },
                    set: { binding.wrappedValue.spokenPhrase = $0 ? "Bell" : nil }
                ))
                if profile.spokenPhrase != nil {
                    TextField("Phrase", text: Binding(
                        get: { binding.wrappedValue.spokenPhrase ?? "" },
                        set: { binding.wrappedValue.spokenPhrase = $0 }
                    ))
                }
            }
            Section {
                ValueStepper(title: "Minimum Time Between Bells", value: binding.throttleInterval, range: 0...5, step: 0.25) {
                    String(format: "%.2g seconds", $0)
                }
                Toggle("Quiet Hours", isOn: Binding(
                    get: { binding.wrappedValue.quietHours != nil },
                    set: { binding.wrappedValue.quietHours = $0 ? QuietHours(startMinute: 22 * 60, endMinute: 7 * 60) : nil }
                ))
                if let quiet = profile.quietHours {
                    DatePicker("Starts", selection: minuteBinding(binding, start: true, current: quiet.startMinute), displayedComponents: .hourAndMinute)
                    DatePicker("Ends", selection: minuteBinding(binding, start: false, current: quiet.endMinute), displayedComponents: .hourAndMinute)
                    Toggle("Allow Haptics During Quiet Hours", isOn: Binding(
                        get: { binding.wrappedValue.quietHours?.allowHaptics ?? true },
                        set: { binding.wrappedValue.quietHours?.allowHaptics = $0 }
                    ))
                }
            } header: {
                SectionHeader("Limits")
            } footer: {
                FooterText("Bells that arrive faster than the minimum time are ignored, so a burst of bells doesn’t become noise.")
            }
            Section {
                Button("Restore Built-In Bell Styles") { settings.restoreBellPresets() }
            }
        }
        .fileImporter(isPresented: $importingSound, allowedContentTypes: [.audio]) { importSound($0) }
        .confirmationDialog("Delete “\(deletingSound.map(SoundLibrary.displayName) ?? "")”?", isPresented: Binding(
            get: { deletingSound != nil }, set: { if !$0 { deletingSound = nil } }
        ), titleVisibility: .visible) {
            Button("Delete Sound", role: .destructive) {
                if let deletingSound { model.sounds.delete(deletingSound) }
                deletingSound = nil
            }
        } message: {
            Text("Bell styles using this sound will play a short tone instead.")
        }
    }

    /// Built-in sounds, then imported ones. A selected file that has since been deleted is
    /// still listed so the row doesn't show a blank value.
    private func soundOptions(current: SoundSource) -> [ChoiceOption<SoundSource>] {
        var options = SoundChoice.allCases.map { ChoiceOption($0.source, $0.name) }
        options += model.sounds.sounds.map { ChoiceOption(SoundSource.custom(fileName: $0), SoundLibrary.displayName($0)) }
        if case let .custom(fileName) = current, !model.sounds.sounds.contains(fileName) {
            options.append(ChoiceOption(current, "\(SoundLibrary.displayName(fileName)) (missing)"))
        }
        if !options.contains(where: { $0.value == current }) {
            options.append(ChoiceOption(current, "Custom tone"))
        }
        return options
    }

    private func importSound(_ result: Result<URL, any Error>) {
        do {
            let name = try model.sounds.importSound(from: result.get())
            importError = nil
            var profile = model.settings.bellProfile(id: model.settings.defaultBellID) ?? .default
            profile.sound = .custom(fileName: name)
            model.settings.updateBell(profile)
            Announcer.post(.init("Imported \(SoundLibrary.displayName(name)). It's now the bell sound.", kind: .event))
        } catch {
            importError = error.localizedDescription
            Announcer.post(.init(error.localizedDescription, priority: .high, kind: .event))
        }
    }

    private func minuteBinding(_ profile: Binding<BellProfile>, start: Bool, current: Int) -> Binding<Date> {
        Binding<Date>(
            get: { Calendar.current.date(bySettingHour: current / 60, minute: current % 60, second: 0, of: Date()) ?? Date() },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
                if start { profile.wrappedValue.quietHours?.startMinute = minute } else { profile.wrappedValue.quietHours?.endMinute = minute }
            }
        )
    }
}
