import SwiftUI
import SwiftData
import AVFoundation

/// App entry point. Sets up the SwiftData database and the audio session.
@main
struct EightCountApp: App {
    /// Only needed so some screens can turn to landscape (see OrientationLock).
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // `.playback` makes the video's sound play even when the ring/silent
        // switch is on — important in a practice room.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        // Lets the Apple Watch app control playback (if there is a watch).
        WatchRemote.shared.activate()
    }

    var body: some Scene {
        WindowGroup {
            ProjectListView()
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
        // Creates (or opens) the on-device database for all model types.
        .modelContainer(for: [Project.self, CountNote.self, PoseSnapshot.self, Take.self, PracticeSection.self])
    }
}
