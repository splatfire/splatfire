import Foundation
import WatchConnectivity

/// The iPhone side of the Apple Watch remote.
///
/// Screens that can be controlled (practice, compare) `attach` themselves
/// while they're open; the newest one on top gets the watch's buttons. The
/// watch is kept up to date by checking twice a second what the top screen
/// is doing and sending it only when something changed.
@MainActor
final class WatchRemote: NSObject {
    static let shared = WatchRemote()

    /// One screen that can be controlled from the watch.
    struct Handler {
        let id: UUID
        let state: @MainActor () -> RemoteState
        let perform: @MainActor (RemoteCommand) -> Void
    }

    private var handlers: [Handler] = []
    private var lastSent: RemoteState?
    private var timer: Timer?
    private var session: WCSession? { WCSession.isSupported() ? WCSession.default : nil }

    /// Call once at app start.
    func activate() {
        guard let session, session.delegate == nil else { return }
        session.delegate = self
        session.activate()
    }

    /// A screen opened (or came back to the front). Re-attaching with the
    /// same id moves it to the top.
    func attach(id: UUID,
                state: @escaping @MainActor () -> RemoteState,
                perform: @escaping @MainActor (RemoteCommand) -> Void) {
        handlers.removeAll { $0.id == id }
        handlers.append(Handler(id: id, state: state, perform: perform))
        startTimerIfNeeded()
        pushIfChanged()
    }

    /// The screen closed.
    func detach(id: UUID) {
        handlers.removeAll { $0.id == id }
        pushIfChanged()
        if handlers.isEmpty {
            timer?.invalidate()
            timer = nil
        }
    }

    private var currentState: RemoteState {
        handlers.last?.state() ?? .idle
    }

    private func handle(_ command: RemoteCommand) -> RemoteState {
        if command != .hello {
            handlers.last?.perform(command)
        }
        let state = currentState
        lastSent = state
        return state
    }

    private func startTimerIfNeeded() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.pushIfChanged()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Sends the state to the watch if it changed and a watch app is there.
    private func pushIfChanged() {
        guard let session, session.activationState == .activated,
              session.isPaired, session.isWatchAppInstalled else { return }
        let state = currentState
        guard state != lastSent else { return }
        lastSent = state
        let payload = state.dictionary
        // Instant when the watch app is open; the context is kept for when it opens later.
        if session.isReachable {
            session.sendMessage(["state": payload], replyHandler: nil, errorHandler: nil)
        }
        try? session.updateApplicationContext(payload)
    }
}

extension WatchRemote: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        Task { @MainActor in
            self.lastSent = nil
            self.pushIfChanged()
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        // The user switched to another watch: connect to the new one.
        session.activate()
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            self.lastSent = nil
            self.pushIfChanged()
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                             replyHandler: @escaping ([String: Any]) -> Void) {
        let command = RemoteCommand(dictionary: message) ?? .hello
        Task { @MainActor in
            let state = self.handle(command)
            replyHandler(state.dictionary)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let command = RemoteCommand(dictionary: message) else { return }
        Task { @MainActor in
            _ = self.handle(command)
        }
    }
}
