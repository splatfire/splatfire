import Foundation

// What the iPhone app and the Apple Watch app say to each other
// (over WatchConnectivity). This file is part of BOTH apps.
//
// Watch → iPhone: a `RemoteCommand` ("play/pause", "back one 8-count", ...).
// iPhone → watch: a `RemoteState` (what the open screen is doing right now).
// Everything is sent as a plain dictionary, which WatchConnectivity requires.

/// A button pressed on the watch.
enum RemoteCommand: Equatable, Sendable {
    /// "Tell me what's going on" (sent when the watch app opens).
    case hello
    case playPause
    /// Back to the start of this 8-count (or the one before, if you're right at the start).
    case back
    /// On to the next 8-count.
    case forward
    case toggleLoop
    case setRate(Float)

    var dictionary: [String: Any] {
        switch self {
        case .hello: return ["cmd": "hello"]
        case .playPause: return ["cmd": "playPause"]
        case .back: return ["cmd": "back"]
        case .forward: return ["cmd": "forward"]
        case .toggleLoop: return ["cmd": "loop"]
        case .setRate(let rate): return ["cmd": "rate", "rate": Double(rate)]
        }
    }

    init?(dictionary: [String: Any]) {
        switch dictionary["cmd"] as? String {
        case "hello": self = .hello
        case "playPause": self = .playPause
        case "back": self = .back
        case "forward": self = .forward
        case "loop": self = .toggleLoop
        case "rate":
            guard let rate = dictionary["rate"] as? Double, rate > 0 else { return nil }
            self = .setRate(Float(rate))
        default: return nil
        }
    }
}

/// What the watch shows.
struct RemoteState: Equatable, Sendable {
    /// True when a screen with a video is open on the iPhone (the buttons work).
    var active: Bool
    /// Project name, e.g. "Setsuna Hanabi".
    var title: String
    /// Shown when nothing can be controlled, e.g. "Open a project on your iPhone".
    var message: String?
    /// "Practice" or "Compare".
    var screen: String
    /// "8-count 5", "Intro", or nil without a BPM.
    var count: String?
    var playing: Bool
    var rate: Float
    var looping: Bool

    /// The speeds the watch offers (same as the iPhone's buttons).
    static let speeds: [Float] = [0.25, 0.5, 0.75, 1.0, 2.0]

    static let idle = RemoteState(active: false, title: "EightCount",
                                  message: "Open a project on your iPhone.",
                                  screen: "", count: nil, playing: false, rate: 1, looping: false)

    var dictionary: [String: Any] {
        var d: [String: Any] = [
            "v": 1,
            "active": active,
            "title": title,
            "screen": screen,
            "playing": playing,
            "rate": Double(rate),
            "looping": looping,
        ]
        if let message { d["message"] = message }
        if let count { d["count"] = count }
        return d
    }

    init(active: Bool, title: String, message: String? = nil, screen: String,
         count: String?, playing: Bool, rate: Float, looping: Bool) {
        self.active = active
        self.title = title
        self.message = message
        self.screen = screen
        self.count = count
        self.playing = playing
        self.rate = rate
        self.looping = looping
    }

    init?(dictionary d: [String: Any]) {
        guard d["v"] as? Int == 1, let active = d["active"] as? Bool else { return nil }
        self.init(active: active,
                  title: d["title"] as? String ?? "EightCount",
                  message: d["message"] as? String,
                  screen: d["screen"] as? String ?? "",
                  count: d["count"] as? String,
                  playing: d["playing"] as? Bool ?? false,
                  rate: Float(d["rate"] as? Double ?? 1),
                  looping: d["looping"] as? Bool ?? false)
    }

    /// "0.75×", "1×".
    static func speedLabel(_ rate: Float) -> String {
        String(format: "%g×", Double(rate))
    }
}
