import SwiftUI
import RoomPlan
import ARKit

/// Bettet RoomPlans `RoomCaptureView` ein — mit der geteilten ARSession des
/// Koordinators, damit die anschließende Leitungsphase im selben
/// Koordinatensystem arbeitet (iOS 17: eigene ARSession für RoomPlan).
struct RoomCaptureViewRepresentable: UIViewRepresentable {
    @ObservedObject var scan: ScanCoordinator

    func makeUIView(context: Context) -> RoomCaptureView {
        let view = RoomCaptureView(frame: .zero, arSession: scan.arSession)
        view.delegate = context.coordinator
        scan.roomCaptureView = view

        var configuration = RoomCaptureSession.Configuration()
        configuration.isCoachingEnabled = true
        view.captureSession.run(configuration: configuration)
        return view
    }

    func updateUIView(_ uiView: RoomCaptureView, context: Context) {}

    func makeCoordinator() -> Delegate {
        Delegate(scan: scan)
    }

    // RoomCaptureViewDelegate verlangt NSCoding-Konformität.
    final class Delegate: NSObject, RoomCaptureViewDelegate {
        private let scan: ScanCoordinator

        init(scan: ScanCoordinator) {
            self.scan = scan
            super.init()
        }

        func captureView(shouldPresent roomDataForProcessing: CapturedRoomData,
                         error: Error?) -> Bool {
            true
        }

        func captureView(didPresent processedResult: CapturedRoom, error: Error?) {
            let room: CapturedRoom? = error == nil ? processedResult : nil
            Task { @MainActor in
                scan.roomFinished(room)
            }
        }

        func encode(with coder: NSCoder) {}

        init?(coder: NSCoder) {
            return nil
        }
    }
}
