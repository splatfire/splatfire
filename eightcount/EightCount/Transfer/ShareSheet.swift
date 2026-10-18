import SwiftUI
import UIKit

/// The standard iOS share sheet (AirDrop, Messages, Save to Files, ...)
/// wrapped for SwiftUI. Show it inside `.sheet`.
@MainActor
struct ShareSheet: UIViewControllerRepresentable {
    /// What to share, e.g. `[fileURL]`.
    let items: [Any]
    /// Called when the user finished sharing or cancelled. Optional.
    var onComplete: (() -> Void)? = nil

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.completionWithItemsHandler = { activityType, completed, _, _ in
            // `activityType == nil` means the share sheet itself was closed.
            // If only a sub-screen (e.g. Mail) was cancelled, the sheet stays open.
            if completed || activityType == nil {
                onComplete?()
            }
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {
        // Nothing to update: the items don't change while the sheet is open.
    }
}
