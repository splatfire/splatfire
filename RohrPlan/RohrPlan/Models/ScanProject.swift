import Foundation

/// Ein Aufmaß-Projekt: Raumhülle aus dem RoomPlan-Scan plus alle erfassten
/// Leitungsläufe und Anlagenmarker im selben Koordinatensystem.
struct ScanProject: Codable, Identifiable {
    var id = UUID()
    var name: String
    var customer: String = ""
    var createdAt = Date()
    var updatedAt = Date()

    var room = RoomShell()
    var pipes: [PipeRun] = []
    var equipment: [Equipment] = []

    /// JSON-kodierter `CapturedRoom` des Original-Scans, damit später noch
    /// ein USDZ-Modell exportiert werden kann.
    var capturedRoomData: Data?

    var totalPipeLength: Float {
        pipes.reduce(0) { $0 + $1.length }
    }

    var hasScanData: Bool {
        !room.isEmpty || !pipes.isEmpty || !equipment.isEmpty
    }
}
