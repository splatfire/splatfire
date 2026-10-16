import AVKit
import SwiftUI

/// The system AirPlay button: pick an Apple TV / AirPlay TV and the video
/// plays there, while the phone (and the watch) stay the remote.
struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.prioritizesVideoDevices = true
        picker.tintColor = .white
        picker.activeTintColor = UIColor(Theme.accent)
        picker.accessibilityLabel = "Play on TV"
        return picker
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
