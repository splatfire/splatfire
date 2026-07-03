import SwiftUI

/// Bedienelemente der Leitungsphase: Systemwahl, Nennweite, Punkt setzen,
/// Lauf abschließen, Anlagenmarker, Fadenkreuz mit Entfernungsanzeige.
struct PipeScanOverlay: View {
    @ObservedObject var scan: ScanCoordinator
    let onFinish: () -> Void
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            crosshair
            VStack(spacing: 0) {
                topBar
                Spacer()
                bottomControls
            }
        }
    }

    // MARK: - Oben: System & Nennweite

    private var topBar: some View {
        VStack(spacing: 8) {
            HStack {
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.headline)
                        .padding(12)
                        .background(.ultraThinMaterial, in: Circle())
                }
                Spacer()
                Menu {
                    Picker("Nennweite", selection: $scan.activeDiameter) {
                        ForEach(NominalDiameter.allCases) { dn in
                            Text(dn.label).tag(dn)
                        }
                    }
                } label: {
                    Text(scan.activeDiameter.label)
                        .font(.headline.monospacedDigit())
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule())
                }
            }
            .padding(.horizontal)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(PipeSystem.allCases) { system in
                        Button {
                            scan.activeSystem = system
                        } label: {
                            HStack(spacing: 6) {
                                Circle().fill(system.color).frame(width: 10, height: 10)
                                Text(system.shortCode).font(.subheadline.bold())
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(
                                scan.activeSystem == system
                                    ? AnyShapeStyle(system.color.opacity(0.35))
                                    : AnyShapeStyle(.ultraThinMaterial),
                                in: Capsule())
                            .overlay(
                                Capsule().strokeBorder(
                                    scan.activeSystem == system ? system.color : .clear,
                                    lineWidth: 2))
                        }
                        .foregroundStyle(.white)
                    }
                }
                .padding(.horizontal)
            }
        }
        .padding(.top, 8)
    }

    // MARK: - Mitte: Fadenkreuz

    private var crosshair: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .strokeBorder(scan.hasTarget ? scan.activeSystem.color : .gray, lineWidth: 2)
                    .frame(width: 36, height: 36)
                Image(systemName: "plus")
                    .font(.caption)
                    .foregroundStyle(scan.hasTarget ? scan.activeSystem.color : .gray)
            }
            if let distance = scan.reticleDistance {
                Text(String(format: "%.2f m", distance))
                    .font(.caption.monospacedDigit())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.ultraThinMaterial, in: Capsule())
            }
        }
    }

    // MARK: - Unten: Aktionen

    private var bottomControls: some View {
        VStack(spacing: 10) {
            if !scan.currentPoints.isEmpty {
                Text("\(scan.currentPoints.count) Punkte · \(String(format: "%.2f m", scan.currentRunLength)) · \(scan.activeSystem.shortCode) \(scan.activeDiameter.label)")
                    .font(.caption.monospacedDigit())
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
            } else {
                Text("Fadenkreuz auf die Leitung richten und Punkte entlang des Rohrverlaufs setzen.")
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .foregroundStyle(.white.opacity(0.9))
                    .shadow(radius: 2)
            }

            HStack(spacing: 14) {
                Button(action: scan.undo) {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.title3)
                        .frame(width: 52, height: 52)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .disabled(scan.currentPoints.isEmpty && scan.pipes.isEmpty)

                Button(action: scan.setPoint) {
                    ZStack {
                        Circle()
                            .fill(scan.activeSystem.color)
                            .frame(width: 74, height: 74)
                        Image(systemName: "plus")
                            .font(.title.bold())
                            .foregroundStyle(.white)
                    }
                }
                .disabled(!scan.hasTarget)
                .opacity(scan.hasTarget ? 1 : 0.4)

                Button(action: scan.finishRun) {
                    Image(systemName: "checkmark")
                        .font(.title3)
                        .frame(width: 52, height: 52)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .disabled(scan.currentPoints.count < 2)

                Menu {
                    ForEach(EquipmentKind.allCases) { kind in
                        Button {
                            scan.addEquipment(kind)
                        } label: {
                            Label(kind.label, systemImage: kind.systemImage)
                        }
                    }
                } label: {
                    Image(systemName: "wrench.and.screwdriver")
                        .font(.title3)
                        .frame(width: 52, height: 52)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .disabled(!scan.hasTarget)
            }
            .foregroundStyle(.white)

            Button {
                onFinish()
            } label: {
                Label("Scan abschließen & speichern", systemImage: "square.and.arrow.down")
                    .font(.headline)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(Color.accentColor, in: Capsule())
                    .foregroundStyle(.white)
            }
            .padding(.bottom, 12)
        }
        .padding(.bottom, 8)
    }
}
