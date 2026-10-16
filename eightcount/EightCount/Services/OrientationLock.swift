import SwiftUI
import UIKit

/// Most screens are portrait-only. The record and compare screens may also
/// turn sideways (landscape). iOS asks the app delegate which orientations
/// are allowed; `OrientationLock` changes that answer at runtime.
///
/// Usage: `.onAppear { OrientationLock.allowLandscape() }`
///        `.onDisappear { OrientationLock.portraitOnly() }`
@MainActor
enum OrientationLock {
    /// What the app currently allows (read by `AppDelegate`).
    static var mask: UIInterfaceOrientationMask = .portrait

    static func allowLandscape() { set(.allButUpsideDown) }

    static func portraitOnly() { set(.portrait) }

    private static func set(_ newMask: UIInterfaceOrientationMask) {
        mask = newMask
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first else { return }
        // Tell UIKit the allowed set changed …
        for window in scene.windows {
            window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        }
        // … and rotate back to portrait right away when locking.
        if newMask == .portrait {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait)) { _ in }
        }
    }
}

/// Minimal app delegate, only used for the orientation lock.
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        OrientationLock.mask
    }
}
