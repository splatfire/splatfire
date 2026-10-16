import Foundation
import Observation
import WatchConnectivity

/// The watch side of the remote: sends button presses to the iPhone and
/// receives what the iPhone is doing.
@MainActor
@Observable
final class PhoneLink: NSObject {
    /// What the iPhone screen is doing (what the watch shows).
    private(set) var state: RemoteState = .idle
    /// True while the iPhone app can be reached right now.
    private(set) var reachable = false
    /// Shown briefly when a button press didn't get through.
    private(set) var problem: String?

    @ObservationIgnored private var problemTask: Task<Void, Never>?

    func start() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        if session.delegate == nil {
            session.delegate = self
            session.activate()
        } else {
            refresh()
        }
    }

    /// Asks the iPhone for its current state.
    func refresh() {
        send(.hello, quiet: true)
    }

    /// Sends a button press. The reply is the new state.
    func send(_ command: RemoteCommand, quiet: Bool = false) {
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else {
            if !quiet { show("Open EightCount on your iPhone.") }
            return
        }
        session.sendMessage(command.dictionary, replyHandler: { reply in
            let state = RemoteState(dictionary: reply)
            Task { @MainActor in
                if let state { self.state = state }
            }
        }, errorHandler: { _ in
            Task { @MainActor in
                if !quiet { self.show("Couldn't reach your iPhone.") }
            }
        })
    }

    private func show(_ message: String) {
        problem = message
        problemTask?.cancel()
        problemTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            problem = nil
        }
    }
}

extension PhoneLink: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        let context = RemoteState(dictionary: session.receivedApplicationContext)
        let reachable = session.isReachable
        Task { @MainActor in
            if let context { self.state = context }
            self.reachable = reachable
            self.refresh()
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in
            self.reachable = reachable
            if reachable { self.refresh() }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        let state = RemoteState(dictionary: applicationContext)
        Task { @MainActor in
            if let state { self.state = state }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let payload = message["state"] as? [String: Any],
              let state = RemoteState(dictionary: payload) else { return }
        Task { @MainActor in
            self.state = state
        }
    }
}
