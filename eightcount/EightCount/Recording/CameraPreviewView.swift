import SwiftUI
import AVFoundation
import UIKit

/// Shows the live front-camera picture (like a mirror: left is left).
///
/// The picture fills the whole area (cropping the edges if needed).
@MainActor
struct CameraPreviewView: UIViewRepresentable {
    let recorder: CameraRecorder

    func makeUIView(context: Context) -> CameraPreviewUIView {
        let view = CameraPreviewUIView()
        view.previewLayer.session = recorder.session
        view.previewLayer.videoGravity = .resizeAspectFill
        // The front camera preview is mirrored automatically
        // (`automaticallyAdjustsVideoMirroring` stays on), like a mirror.
        // The recorder keeps the preview upright when the phone is turned.
        recorder.attach(previewLayer: view.previewLayer)
        return view
    }

    func updateUIView(_ uiView: CameraPreviewUIView, context: Context) {
        // Nothing to update: the session is set once in `makeUIView`.
    }
}

/// A UIView whose own layer *is* an `AVCaptureVideoPreviewLayer`, so the
/// camera picture always resizes together with the view.
final class CameraPreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var previewLayer: AVCaptureVideoPreviewLayer {
        // Safe: `layerClass` above guarantees the layer type.
        layer as! AVCaptureVideoPreviewLayer
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }
}
