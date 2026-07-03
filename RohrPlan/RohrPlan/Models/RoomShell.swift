import Foundation
import RoomPlan

/// Dauerhaft speicherbare, vereinfachte Abbildung eines RoomPlan-Scans.
/// RoomPlan-Flächen sind zentrierte Quader: `transform` legt Lage und
/// Ausrichtung fest, `dimensions` die Ausdehnung (x = Breite, y = Höhe).
struct PlanSurface: Codable, Identifiable {
    enum Kind: String, Codable {
        case wall, door, window, opening
    }

    var id = UUID()
    var kind: Kind
    var transform: Matrix4
    var dimensions: Vector3
}

/// Von RoomPlan erkannte Einrichtungsobjekte (Möbel etc.) — nur zur
/// Orientierung im Plan, nicht Teil der Leitungsdaten.
struct PlanObject: Codable, Identifiable {
    var id = UUID()
    var category: String
    var transform: Matrix4
    var dimensions: Vector3
}

struct RoomShell: Codable {
    var surfaces: [PlanSurface] = []
    var objects: [PlanObject] = []

    var isEmpty: Bool { surfaces.isEmpty && objects.isEmpty }

    var walls: [PlanSurface] { surfaces.filter { $0.kind == .wall } }
    var doors: [PlanSurface] { surfaces.filter { $0.kind == .door } }
    var windows: [PlanSurface] { surfaces.filter { $0.kind == .window } }
    var openings: [PlanSurface] { surfaces.filter { $0.kind == .opening } }
}

extension RoomShell {
    init(capturedRoom: CapturedRoom) {
        func convert(_ list: [CapturedRoom.Surface], as kind: PlanSurface.Kind) -> [PlanSurface] {
            list.map {
                PlanSurface(kind: kind,
                            transform: Matrix4($0.transform),
                            dimensions: Vector3($0.dimensions))
            }
        }

        surfaces = convert(capturedRoom.walls, as: .wall)
            + convert(capturedRoom.doors, as: .door)
            + convert(capturedRoom.windows, as: .window)
            + convert(capturedRoom.openings, as: .opening)

        objects = capturedRoom.objects.map {
            PlanObject(category: String(describing: $0.category),
                       transform: Matrix4($0.transform),
                       dimensions: Vector3($0.dimensions))
        }
    }
}
