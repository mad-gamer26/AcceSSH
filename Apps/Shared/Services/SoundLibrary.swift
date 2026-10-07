import Foundation
import AVFoundation
import Observation
import AcceSSHCore

/// Audio files the person imported for the bell (and, later, other events). Files are copied
/// into Application Support/AcceSSH/Sounds, so the original can be deleted or moved.
@MainActor @Observable
final class SoundLibrary {
    /// File names, sorted for display.
    private(set) var sounds: [String] = []

    nonisolated static let maximumDuration: TimeInterval = 10
    nonisolated static let maximumFileSize = 10 * 1_024 * 1_024

    enum ImportError: LocalizedError {
        case unreadable
        case notAudio
        case tooLong(TimeInterval)
        case tooLarge

        var errorDescription: String? {
            switch self {
            case .unreadable:
                "The file couldn’t be read."
            case .notAudio:
                "That file isn’t a sound AcceSSH can play. Use a WAV, AIFF, CAF, MP3 or M4A file."
            case let .tooLong(duration):
                "That sound is \(Int(duration.rounded())) seconds long. Bell sounds can be up to \(Int(SoundLibrary.maximumDuration)) seconds."
            case .tooLarge:
                "That file is larger than 10 MB."
            }
        }
    }

    let directory: URL = {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AcceSSH/Sounds", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    init() {
        reload()
    }

    private func reload() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        sounds = names.filter { !$0.hasPrefix(".") }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func url(for fileName: String) -> URL {
        directory.appendingPathComponent(fileName)
    }

    /// Copies an audio file into the library after checking that it plays and is short.
    /// Returns the stored file name.
    @discardableResult
    func importSound(from source: URL) throws -> String {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }

        let size = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= Self.maximumFileSize else { throw ImportError.tooLarge }
        guard let data = try? Data(contentsOf: source) else { throw ImportError.unreadable }
        guard let player = try? AVAudioPlayer(data: data) else { throw ImportError.notAudio }
        guard player.duration <= Self.maximumDuration else { throw ImportError.tooLong(player.duration) }

        // Keep the original name, adding a number if it's taken.
        let base = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension
        var name = source.lastPathComponent
        var counter = 2
        while FileManager.default.fileExists(atPath: url(for: name).path) {
            name = "\(base) \(counter)" + (ext.isEmpty ? "" : ".\(ext)")
            counter += 1
        }
        try data.write(to: url(for: name), options: .atomic)
        reload()
        return name
    }

    func delete(_ fileName: String) {
        try? FileManager.default.removeItem(at: url(for: fileName))
        reload()
    }

    /// Display name without the file extension.
    static func displayName(_ fileName: String) -> String {
        (fileName as NSString).deletingPathExtension
    }
}

/// Plays imported sound files. Keeps a reference so playback isn't cut off.
@MainActor
enum SoundFilePlayer {
    private static var player: AVAudioPlayer?

    /// Plays a file from the sound library. Returns false if the file is missing or unplayable.
    @discardableResult
    static func play(fileName: String, volume: Double) -> Bool {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AcceSSH/Sounds", isDirectory: true)
            .appendingPathComponent(fileName)
        try? AVAudioSession.sharedInstance().setCategory(.ambient, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        guard let player = try? AVAudioPlayer(contentsOf: url) else { return false }
        player.volume = Float(min(max(volume, 0), 1))
        player.prepareToPlay()
        player.play()
        self.player = player
        return true
    }
}
