import AVFoundation
import Foundation
import QuartzCore

/// The beeps of the record countdown (like TikTok's timer): a short tick at
/// 3, 2 and 1, and a brighter ding at "go", exactly when the tutorial music
/// starts.
///
/// Each beep has its OWN `AVAudioPlayer`, so all four can be scheduled ahead
/// of time with `play(atTime:)` on the audio device's clock (sample accurate,
/// no timers involved). A player can only be scheduled once per `schedule`
/// call, so they are rewound and prepared again every time.
///
/// The app's audio session is `.playback` (set by the record screen), so the
/// beeps are heard with the silent switch on and mix with the tutorial music.
/// The camera records no sound, so the beeps never end up in a take.
@MainActor
final class CountdownSounds {
    private static let volume: Float = 0.9

    private var tickPlayers: [AVAudioPlayer] = []
    private var goPlayer: AVAudioPlayer?
    private var didPreload = false
    /// Only used when the device clock is unavailable (see `schedule`).
    private var fallbackTask: Task<Void, Never>?

    init() {}

    /// Loads the sound files (once) so the first countdown starts instantly.
    func preload() {
        guard !didPreload else { return }
        didPreload = true
        tickPlayers = (0..<3).compactMap { _ in Self.makePlayer(named: "countdown-tick") }
        goPlayer = Self.makePlayer(named: "countdown-go")
    }

    /// Schedules tick, tick, tick, go: one second apart, the first tick
    /// `hostDelay` seconds from now (0 = right now), the "go" ding
    /// 3 intervals after the first tick.
    func schedule(startingAt hostDelay: TimeInterval = 0, interval: TimeInterval = 1) {
        preload()
        cancel()

        var beeps: [(player: AVAudioPlayer, delay: TimeInterval)] = []
        for (index, player) in tickPlayers.enumerated() {
            beeps.append((player, hostDelay + Double(index) * interval))
        }
        if let goPlayer {
            beeps.append((goPlayer, hostDelay + Double(tickPlayers.count) * interval))
        }
        guard !beeps.isEmpty else { return }

        // Rewind + prepare (stop() throws the preparation away).
        for beep in beeps {
            beep.player.currentTime = 0
            beep.player.prepareToPlay()
        }

        // All players share the output device's clock: read it once.
        let base = beeps[0].player.deviceCurrentTime
        if base > 0 {
            for beep in beeps {
                // A time in the past plays at once, so never schedule earlier than "now".
                beep.player.play(atTime: base + max(beep.delay, 0.01))
            }
        } else {
            // No device clock yet: fall back to plain timers (less precise).
            fallbackTask = Task { @MainActor in
                let began = CACurrentMediaTime()
                for beep in beeps {
                    let wait = beep.delay - (CACurrentMediaTime() - began)
                    if wait > 0 {
                        try? await Task.sleep(for: .seconds(wait))
                    }
                    guard !Task.isCancelled else { return }
                    beep.player.play()
                }
            }
        }
    }

    /// Silences everything that is scheduled or playing.
    func cancel() {
        fallbackTask?.cancel()
        fallbackTask = nil
        for player in tickPlayers { player.stop() }
        goPlayer?.stop()
    }

    private static func makePlayer(named name: String) -> AVAudioPlayer? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "wav") else { return nil }
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.volume = volume
            player.numberOfLoops = 0
            player.prepareToPlay()
            return player
        } catch {
            return nil
        }
    }
}
