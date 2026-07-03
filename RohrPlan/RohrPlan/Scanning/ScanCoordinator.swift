import Foundation
import ARKit
import RoomPlan

/// Steuert den zweiphasigen Scan: erst die Raumhülle mit RoomPlan, danach
/// die Leitungserfassung per LiDAR-Raycast. Beide Phasen laufen auf
/// derselben `ARSession`, damit Raum und Leitungen im selben
/// Weltkoordinatensystem liegen — das ist der Kern der App: Leitungen
/// bleiben als eigene Plandaten erhalten statt wie bei RoomPlan/Polycam
/// aus dem Ergebnis herauszufallen.
@MainActor
final class ScanCoordinator: ObservableObject {
    enum Phase {
        case room        // RoomPlan-Scan läuft
        case processing  // RoomPlan berechnet den Grundriss
        case pipes       // Leitungen werden markiert
    }

    @Published var phase: Phase = .room

    // Ergebnis der Raumphase
    @Published var capturedRoom: CapturedRoom?
    @Published var shell = RoomShell()

    // Ergebnis der Leitungsphase
    @Published var pipes: [PipeRun] = []
    @Published var equipment: [Equipment] = []

    // Werkzeugzustand der Leitungsphase
    @Published var activeSystem: PipeSystem = .heizungVorlauf
    @Published var activeDiameter: NominalDiameter = .dn20
    @Published var currentPoints: [SIMD3<Float>] = []
    @Published var hasTarget = false
    @Published var reticleDistance: Float?

    /// Aktueller Raycast-Treffer unter dem Fadenkreuz (jede Frame aktualisiert).
    var currentTarget: SIMD3<Float>?

    let arSession = ARSession()
    weak var roomCaptureView: RoomCaptureView?

    static var isRoomScanSupported: Bool {
        RoomCaptureSession.isSupported
    }

    // MARK: - Raumphase

    func finishRoomScan() {
        phase = .processing
        // ARSession weiterlaufen lassen, damit die Leitungsphase im selben
        // Bezugssystem weiterarbeiten kann.
        roomCaptureView?.captureSession.stop(pauseARSession: false)
    }

    func skipRoomScan() {
        roomCaptureView?.captureSession.stop(pauseARSession: false)
        phase = .pipes
    }

    func roomFinished(_ room: CapturedRoom?) {
        if let room {
            capturedRoom = room
            shell = RoomShell(capturedRoom: room)
        }
        phase = .pipes
    }

    // MARK: - Leitungsphase

    var currentRunLength: Float {
        zip(currentPoints, currentPoints.dropFirst())
            .reduce(0) { $0 + simd_distance($1.0, $1.1) }
    }

    func setPoint() {
        guard let target = currentTarget else { return }
        currentPoints.append(target)
    }

    /// Entfernt zuerst den letzten Punkt des laufenden Laufs; ist keiner
    /// offen, wird der zuletzt abgeschlossene Lauf entfernt.
    func undo() {
        if !currentPoints.isEmpty {
            currentPoints.removeLast()
        } else if !pipes.isEmpty {
            pipes.removeLast()
        }
    }

    func finishRun() {
        defer { currentPoints = [] }
        guard currentPoints.count >= 2 else { return }
        pipes.append(PipeRun(system: activeSystem,
                             diameter: activeDiameter,
                             points: currentPoints.map(Vector3.init)))
    }

    func addEquipment(_ kind: EquipmentKind) {
        guard let target = currentTarget else { return }
        equipment.append(Equipment(kind: kind, position: Vector3(target)))
    }

    // MARK: - Abschluss

    func stopSession() {
        arSession.pause()
    }

    /// Schreibt die Scan-Ergebnisse in das Projekt. Ein neuer Scan ersetzt
    /// die bisherigen Daten, weil jede ARSession ihren eigenen Weltursprung
    /// hat und alte Koordinaten dazu nicht passen würden.
    func apply(to project: inout ScanProject) {
        finishRun()
        project.room = shell
        project.pipes = pipes
        project.equipment = equipment
        project.capturedRoomData = capturedRoom.flatMap { try? JSONEncoder().encode($0) }
    }
}
