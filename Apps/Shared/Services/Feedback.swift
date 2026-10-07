import Foundation
import AVFoundation
import AcceSSHCore
import UIKit
import CoreHaptics
import AudioToolbox

/// Plays synthesized tones (sine, triangle, square, optionally two notes). Tones are
/// generated in memory, so no sound files ship with the app.
@MainActor
final class TonePlayer {
    static let shared = TonePlayer()

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    private var isConfigured = false

    private func configure() -> Bool {
        if isConfigured { return true }
        // Ambient: mixes with other audio and VoiceOver, respects the Ring/Silent switch.
        try? AVAudioSession.sharedInstance().setCategory(.ambient, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
        } catch {
            return false
        }
        isConfigured = true
        return true
    }

    func play(_ tone: ToneSpec, volume: Double) {
        guard configure(), let buffer = render(tone, volume: volume) else { return }
        if !engine.isRunning { try? engine.start() }
        player.scheduleBuffer(buffer, completionHandler: nil)
        if !player.isPlaying { player.play() }
    }

    private func render(_ tone: ToneSpec, volume: Double) -> AVAudioPCMBuffer? {
        let duration = min(max(tone.duration, 0.02), 2)
        let notes = [tone.frequency] + (tone.secondFrequency.map { [$0] } ?? [])
        let samplesPerNote = Int(format.sampleRate * duration)
        let total = samplesPerNote * notes.count
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(total)),
              let channel = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = AVAudioFrameCount(total)
        let amplitude = Float(min(max(volume, 0), 1)) * 0.5
        let ramp = Int(format.sampleRate * 0.005)  // 5 ms fade avoids clicks
        for (noteIndex, rawFrequency) in notes.enumerated() {
            let frequency = min(max(rawFrequency, 100), 4_000)
            for sample in 0..<samplesPerNote {
                let phase = (Double(sample) * frequency / format.sampleRate).truncatingRemainder(dividingBy: 1)
                let value: Double = switch tone.waveform {
                case .sine: sin(2 * .pi * phase)
                case .triangle: 1 - 4 * abs(phase - 0.5)
                case .square: phase < 0.5 ? 0.6 : -0.6
                }
                let envelope = Float(min(1, Double(min(sample, samplesPerNote - sample)) / Double(max(ramp, 1))))
                channel[noteIndex * samplesPerNote + sample] = Float(value) * amplitude * envelope
            }
        }
        return buffer
    }
}

/// Haptic playback with honest capability detection: Core Haptics patterns only on hardware
/// that supports them (iPhone), basic feedback generators otherwise, nothing where there is
/// no haptic hardware (most iPads).
@MainActor
enum HapticPlayer {
    private static var engine: CHHapticEngine?

    static var supportsCustomPatterns: Bool {
        CHHapticEngine.capabilitiesForHardware().supportsHaptics
    }

    static func play(_ style: HapticStyle) {
        switch style {
        case .none: break
        case .light: UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .medium: UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case .heavy: UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        case .soft: UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        case .rigid: UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        case .success: UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .warning: UINotificationFeedbackGenerator().notificationOccurred(.warning)
        case .error: UINotificationFeedbackGenerator().notificationOccurred(.error)
        case .selection: UISelectionFeedbackGenerator().selectionChanged()
        case let .custom(pattern):
            guard supportsCustomPatterns else {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                return
            }
            playPattern(pattern)
        }
    }

    private static func playPattern(_ pattern: HapticPattern) {
        do {
            if engine == nil {
                engine = try CHHapticEngine()
                engine?.resetHandler = { [weak engine] in try? engine?.start() }
            }
            try engine?.start()
            let events = pattern.events.map { event in
                CHHapticEvent(
                    eventType: event.kind == .transient ? .hapticTransient : .hapticContinuous,
                    parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: Float(event.intensity)),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: Float(event.sharpness)),
                    ],
                    relativeTime: event.time, duration: event.duration
                )
            }
            let player = try engine?.makePlayer(with: CHHapticPattern(events: events, parameters: []))
            try player?.start(atTime: CHHapticTimeImmediate)
        } catch {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
    }

    /// Plain-language description of what this device can do, for the settings screen.
    static var capabilityDescription: String {
        if supportsCustomPatterns { return "This device supports all haptic styles, including custom patterns." }
        if UIDevice.current.userInterfaceIdiom == .pad { return "This iPad has no haptic hardware, so haptics are skipped." }
        return "This device supports basic haptics only. Custom patterns play as a medium tap."
    }
}

/// Responds to the terminal bell according to a bell profile.
@MainActor
enum BellPlayer {
    private static var lastRing = Date.distantPast

    static func ring(profile: BellProfile, speech: SpeechCoordinator?, preview: Bool = false) {
        let now = Date()
        if !preview {
            guard now.timeIntervalSince(lastRing) >= profile.throttleInterval else { return }
            lastRing = now
            if let quietHours = profile.quietHours, quietHours.contains(now) {
                if quietHours.allowHaptics { HapticPlayer.play(profile.haptic) }
                return
            }
        }
        HapticPlayer.play(profile.haptic)
        play(profile.sound, volume: profile.volume)
        if let phrase = profile.spokenPhrase, !phrase.isEmpty {
            // A spoken phrase is an explicit choice in the bell profile, so it is always spoken.
            if let speech {
                speech.say(phrase, priority: .low)
            } else if Announcer.isVoiceOverRunning {
                Announcer.post(.init(phrase, priority: .low, kind: .event))
            }
        }
    }

    static func play(_ sound: SoundSource, volume: Double) {
        switch sound {
        case .none:
            break
        case let .tone(tone):
            TonePlayer.shared.play(tone, volume: volume)
        case .systemAlert:
            AudioServicesPlaySystemSound(1_104)
        case let .custom(fileName):
            // A deleted or damaged file falls back to a short tone so the bell is never silent by accident.
            if !SoundFilePlayer.play(fileName: fileName, volume: volume) {
                TonePlayer.shared.play(ToneSpec(frequency: 880, duration: 0.1), volume: volume)
            }
        case .bundled:
            TonePlayer.shared.play(ToneSpec(frequency: 880, duration: 0.1), volume: volume)
        }
    }
}
