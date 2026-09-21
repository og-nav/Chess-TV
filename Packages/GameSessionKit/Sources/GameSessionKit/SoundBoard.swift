// Audio hardware acquisition and prepared players stay off the UI thread.
// The four sounds are original to this project, synthesized by scripts/make-sounds.py
// into Apps/ChessTV/Resources/Sounds (44.1 kHz, 16-bit, mono WAV).
import AVFoundation

@MainActor
public final class SoundBoard {
    private let playback = SoundPlayback.shared

    public init() {
        Task { await playback.prepare() }
    }

    public func play(_ outcome: MoveOutcome) {
        Task { await playback.play(outcome) }
    }

    public func playGameOver() {
        Task { await playback.playGameOver() }
    }
}

/// AVAudioPlayer.prepareToPlay also acquires hardware and may block, so moving only
/// AVAudioSession.setActive off MainActor is insufficient. All players live on this actor;
/// none cross an isolation boundary. Each process prepares one set, shared by its sessions.
private actor SoundPlayback {
    static let shared = SoundPlayback()
    private var prepared = false
    private var players: [MoveOutcome: AVAudioPlayer] = [:]
    private var gameOver: AVAudioPlayer?

    func prepare() {
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
        for (outcome, name) in [(MoveOutcome.move, "move"), (.capture, "capture"), (.check, "check")] {
            players[outcome] = load(name: name, extension: "wav")
        }
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

    func play(_ outcome: MoveOutcome) {
        prepare()
        play(players[outcome])
    }

    func playGameOver() {
        prepare()
        play(gameOver)
    }

    private func play(_ player: AVAudioPlayer?) {
        guard let player else { return }
        if player.isPlaying { player.stop() }
        player.currentTime = 0
        player.play()
    }
}
