import SwiftUI
import AVFoundation
import UIKit

/// Shows the video (aspect-fit on black). Flips it horizontally when
/// `controller.isMirrored` is on, with a small "MIRRORED" badge.
///
/// We don't use SwiftUI's `VideoPlayer` because its built-in controls would
/// be flipped too, and we have our own controls anyway.
@MainActor
struct VideoSurface: View {
    let controller: PlayerController
    /// Pinch zoom (1 = whole video) and where the zoomed picture is moved to.
    var zoom: CGFloat = 1
    var pan: CGSize = .zero

    init(controller: PlayerController, zoom: CGFloat = 1, pan: CGSize = .zero) {
        self.controller = controller
        self.zoom = zoom
        self.pan = pan
    }

    var body: some View {
        ZStack {
            Theme.background

            PlayerLayerView(player: controller.player)
                // Only the video is flipped; the badge below is not.
                .scaleEffect(x: controller.isMirrored ? -1 : 1, y: 1)
                // Zoom after the flip, so dragging moves the way your finger goes.
                .scaleEffect(zoom)
                .offset(pan)
                .opacity(controller.isReady ? 1 : 0)

            if controller.isOnTV {
                VStack(spacing: 8) {
                    Image(systemName: "tv")
                        .font(.system(size: 34, weight: .semibold))
                    Text("Playing on your TV")
                        .font(.headline)
                    Text("This phone is the remote. The TV shows the video unmirrored.")
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Theme.secondaryText)
                }
                .foregroundStyle(Color.white)
                .padding()
            } else if let error = controller.loadError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .padding()
            } else if !controller.isReady {
                ProgressView()
                    .tint(.white)
                    .controlSize(.large)
            }
        }
        .overlay(alignment: .topTrailing) {
            if controller.isMirrored {
                Text("MIRRORED")
                    .font(.system(.caption2, design: .rounded).weight(.semibold))
                    .tracking(0.8)
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .glassSurface(Capsule(), fallback: Color.black.opacity(0.55))
                    .padding(8)
                    .transition(.opacity)
                    .accessibilityLabel("Video is mirrored")
            }
        }
        .animation(.snappy, value: controller.isMirrored)
        .clipped()
    }
}

/// Bridges a UIKit view that hosts an `AVPlayerLayer` into SwiftUI.
@MainActor
private struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerUIView {
        let view = PlayerUIView()
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ uiView: PlayerUIView, context: Context) {
        if uiView.playerLayer.player !== player {
            uiView.playerLayer.player = player
        }
    }
}

/// A UIView whose own layer *is* an AVPlayerLayer, so the video always
/// resizes together with the view (no manual layout needed).
private final class PlayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer {
        // Safe: `layerClass` above guarantees the layer type.
        layer as! AVPlayerLayer
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        playerLayer.videoGravity = .resizeAspect
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }
}
