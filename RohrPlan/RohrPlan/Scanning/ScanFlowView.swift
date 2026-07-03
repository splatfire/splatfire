import SwiftUI
import RoomPlan

/// Vollbild-Ablauf eines Scans: Raumphase (RoomPlan) → Leitungsphase → Speichern.
struct ScanFlowView: View {
    @EnvironmentObject private var store: ProjectStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var scan = ScanCoordinator()

    let project: ScanProject
    let onSaved: (ScanProject) -> Void

    @State private var showCancelDialog = false

    var body: some View {
        ZStack {
            switch scan.phase {
            case .room, .processing:
                if ScanCoordinator.isRoomScanSupported {
                    RoomCaptureViewRepresentable(scan: scan)
                        .ignoresSafeArea()
                    roomOverlay
                } else {
                    unsupportedView
                }
            case .pipes:
                PipeScanARView(scan: scan)
                    .ignoresSafeArea()
                PipeScanOverlay(scan: scan, onFinish: save, onCancel: { showCancelDialog = true })
            }
        }
        .statusBarHidden()
        .confirmationDialog("Scan verwerfen?", isPresented: $showCancelDialog, titleVisibility: .visible) {
            Button("Verwerfen", role: .destructive) { cancel() }
            Button("Weiter scannen", role: .cancel) {}
        } message: {
            Text("Alle in diesem Scan erfassten Daten gehen verloren.")
        }
    }

    // MARK: - Raumphase

    private var roomOverlay: some View {
        VStack {
            HStack {
                Button {
                    showCancelDialog = true
                } label: {
                    Image(systemName: "xmark")
                        .font(.headline)
                        .padding(12)
                        .background(.ultraThinMaterial, in: Circle())
                }
                Spacer()
            }
            .padding()

            Spacer()

            if scan.phase == .processing {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Grundriss wird berechnet …")
                        .font(.callout)
                }
                .padding(20)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                .padding(.bottom, 40)
            } else {
                VStack(spacing: 12) {
                    Text("Raum langsam mit der Kamera abfahren — Wände, Türen und Fenster werden automatisch erkannt.")
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)

                    Button {
                        scan.finishRoomScan()
                    } label: {
                        Label("Raum fertig — weiter zu Leitungen", systemImage: "checkmark")
                            .font(.headline)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 14)
                            .background(Color.accentColor, in: Capsule())
                            .foregroundStyle(.white)
                    }

                    Button("Ohne Raum-Scan fortfahren") {
                        scan.skipRoomScan()
                    }
                    .font(.footnote)
                }
                .padding(.bottom, 30)
            }
        }
    }

    private var unsupportedView: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.metering.unknown")
                .font(.largeTitle)
            Text("Dieses Gerät hat keinen LiDAR-Scanner.")
                .font(.headline)
            Text("Der Raum-Scan benötigt ein iPhone Pro oder iPad Pro mit LiDAR. Die Leitungserfassung kann eingeschränkt trotzdem genutzt werden.")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Nur Leitungen erfassen") {
                scan.phase = .pipes
            }
            .buttonStyle(.borderedProminent)
            Button("Abbrechen") { dismiss() }
        }
    }

    // MARK: - Abschluss

    private func save() {
        var updated = project
        scan.apply(to: &updated)
        scan.stopSession()
        store.save(updated)
        onSaved(updated)
        dismiss()
    }

    private func cancel() {
        scan.stopSession()
        dismiss()
    }
}
