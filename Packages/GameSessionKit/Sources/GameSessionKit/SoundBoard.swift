// Audio hardware acquisition and prepared players stay off the UI thread.
// Six selectable move/capture/check sets; game over is a shared original chime.
// Sources, processing and licenses are documented in assets/audio/README.md.
import AVFoundation

@MainActor
public final class SoundBoard {
    private let playback = SoundPlayback.shared

    public init(set: SoundSet = .recordedWood) {
        Task { await playback.prepare(set: set) }
    }

    public func play(_ outcome: MoveOutcome, set: SoundSet = .recordedWood) {
        Task { await playback.play(outcome, set: set) }
    }

    public func playGameOver() {
        Task { await playback.playGameOver() }
    }

    /// An explicit preview is audible even when automatic game sounds are muted.
    public func preview(_ set: SoundSet) {
        Task { await playback.preview(set) }
    }

    public func stopPreview() {
        Task { await playback.stopPreview() }
    }
}

/// AVAudioPlayer.prepareToPlay also acquires hardware and may block, so moving only
/// AVAudioSession.setActive off MainActor is insufficient. All players live on this actor;
/// none cross an isolation boundary. Sets load on demand and are shared by game sessions.
private actor SoundPlayback {
    static let shared = SoundPlayback()
    private var prepared = false
    private var players: [SoundSet: [MoveOutcome: AVAudioPlayer]] = [:]
    private var gameOver: AVAudioPlayer?
    private var previewPlayers: [AVAudioPlayer] = []
    private var previewTask: Task<Void, Never>?

    func prepare(set: SoundSet) {
        prepareSession()
        guard players[set] == nil else { return }
        var loaded: [MoveOutcome: AVAudioPlayer] = [:]
        for outcome in MoveOutcome.allCases {
            loaded[outcome] = load(name: set.resourceName(for: outcome), extension: "wav")
        }
        players[set] = loaded
    }

    private func prepareSession() {
        guard !prepared else { return }
        prepared = true
        #if !os(macOS)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.ambient, mode: .default)
            try session.setActive(true)
        } catch {
            appLog.error("Audio session unavailable: \(String(describing: error), privacy: .public)")
        }
        #endif
        gameOver = load(name: "gameover", extension: "wav")
    }

    private func load(name: String, extension ext: String) -> AVAudioPlayer? {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext) else {
            appLog.error("Missing sound \(name, privacy: .public).\(ext, privacy: .public)")
            return nil
        }
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.prepareToPlay()
            return player
        } catch {
            appLog.error("Could not load sound: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    func play(_ outcome: MoveOutcome, set: SoundSet) {
        prepare(set: set)
        play(players[set]?[outcome])
    }

    func playGameOver() {
        prepareSession()
        play(gameOver)
    }

    func preview(_ set: SoundSet) {
        stopPreview()
        prepareSession()
        // Separate players let a live game's move play without cutting off the sample.
        previewPlayers = MoveOutcome.allCases.compactMap {
            load(name: set.resourceName(for: $0), extension: "wav")
        }
        previewTask = Task {
            for player in previewPlayers {
                guard !Task.isCancelled else { return }
                play(player)
                do { try await Task.sleep(for: .seconds(player.duration + 0.3)) }
                catch { return }
            }
            previewPlayers = []
            previewTask = nil
        }
    }

    func stopPreview() {
        previewTask?.cancel()
        previewTask = nil
        for player in previewPlayers { player.stop() }
        previewPlayers = []
    }

    private func play(_ player: AVAudioPlayer?) {
        guard let player else { return }
        if player.isPlaying { player.stop() }
        player.currentTime = 0
        player.play()
    }
}
