import Foundation

/// What the watch buttons do on each iPhone screen.
@MainActor
enum WatchRemoteHandlers {

    // MARK: - Practice screen

    static func attachPractice(id: UUID, project: Project, controller: PlayerController) {
        WatchRemote.shared.attach(id: id, state: {
            let grid = CountGrid(bpm: project.bpm, offset: project.offset, duration: controller.duration)
            return RemoteState(active: controller.isReady, title: project.title,
                               message: controller.isReady ? nil : "Loading the video…",
                               screen: "Practice", count: countText(grid, controller.currentTime),
                               playing: controller.isPlaying, rate: controller.rate,
                               looping: controller.isLooping)
        }, perform: { command in
            guard controller.isReady else { return }
            let grid = CountGrid(bpm: project.bpm, offset: project.offset, duration: controller.duration)
            switch command {
            case .hello:
                break
            case .playPause:
                controller.togglePlayPause()
            case .setRate(let rate):
                controller.setRate(rate)
            case .back, .forward:
                guard grid.isValid else {
                    controller.skip(by: command == .back ? -5 : 5)
                    return
                }
                let target = neighbour(grid, time: controller.currentTime, forward: command == .forward)
                guard let target else {
                    if command == .back { controller.seek(to: 0) }
                    return
                }
                let start = max(grid.start(of: target), 0)
                if controller.loopedEightCount != nil && controller.isLooping {
                    // An 8-count is looping: loop the new one instead.
                    controller.loopEightCount(target, start: start, end: grid.end(of: target))
                } else {
                    controller.seek(to: start)
                }
            case .toggleLoop:
                if controller.isLooping {
                    controller.clearLoop()
                } else if grid.isValid {
                    // Loop the 8-count that's playing (the intro counts as the first).
                    let index = grid.index(at: controller.currentTime) ?? 0
                    controller.loopEightCount(index, start: max(grid.start(of: index), 0),
                                              end: grid.end(of: index))
                    if !controller.isPlaying { controller.play() }
                } else if controller.loopStart != nil, controller.loopEnd != nil {
                    controller.toggleLoop()   // no BPM yet: use the A-B loop
                }
            }
        })
    }

    // MARK: - Compare screen

    static func attachCompare(id: UUID, project: Project, playback: SyncedPlayback) {
        WatchRemote.shared.attach(id: id, state: {
            let grid = CountGrid(bpm: project.bpm, offset: project.offset, duration: playback.tutorialDuration)
            return RemoteState(active: playback.isReady, title: project.title,
                               message: playback.isReady ? nil : "Loading…",
                               screen: "Compare", count: countText(grid, playback.currentTime),
                               playing: playback.isPlaying, rate: playback.rate,
                               looping: playback.isLooping)
        }, perform: { command in
            guard playback.isReady else { return }
            let grid = CountGrid(bpm: project.bpm, offset: project.offset, duration: playback.tutorialDuration)
            switch command {
            case .hello:
                break
            case .playPause:
                playback.togglePlayPause()
            case .setRate(let rate):
                playback.setRate(rate)
            case .back, .forward:
                guard grid.isValid else {
                    playback.seek(to: playback.currentTime + (command == .back ? -3 : 3))
                    return
                }
                if let target = neighbour(grid, time: playback.currentTime, forward: command == .forward) {
                    playback.seek(to: grid.start(of: target))   // kept inside your take by `seek`
                } else if command == .back {
                    playback.seek(to: playback.range.lowerBound)
                }
            case .toggleLoop:
                playback.isLooping.toggle()
            }
        })
    }

    // MARK: - Screens the watch must not control (recording)

    static func attachBlocked(id: UUID, title: String, message: String) {
        WatchRemote.shared.attach(id: id, state: {
            RemoteState(active: false, title: title, message: message, screen: "",
                        count: nil, playing: false, rate: 1, looping: false)
        }, perform: { _ in })
    }

    // MARK: - Helpers

    /// "8-count 5", "Intro" before count 1, nil without a BPM.
    private static func countText(_ grid: CountGrid, _ time: Double) -> String? {
        guard grid.isValid else { return nil }
        guard let index = grid.index(at: time) else { return "Intro" }
        return "8-count \(index + 1)"
    }

    /// The 8-count to jump to. Back: the start of this one, or the previous
    /// one when you're already within 1 s of its start. Nil = before the
    /// first one (back) or past the last one (forward).
    private static func neighbour(_ grid: CountGrid, time: Double, forward: Bool) -> Int? {
        let current = grid.index(at: time)
        if forward {
            let next = (current ?? -1) + 1
            return next < grid.numberOfEightCounts ? next : nil
        }
        guard let current else { return nil }
        let target = time - grid.start(of: current) > 1.0 ? current : current - 1
        return target >= 0 ? target : nil
    }
}
