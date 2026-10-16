import SwiftUI

/// Apple Watch app: a remote control for the EightCount iPhone app.
@main
struct EightCountWatchApp: App {
    @State private var link = PhoneLink()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RemoteView(link: link)
                .onAppear { link.start() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { link.refresh() }
                }
        }
    }
}
