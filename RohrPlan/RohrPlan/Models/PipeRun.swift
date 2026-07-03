import Foundation
import simd

/// Ein erfasster Leitungslauf: eine Polylinie aus Weltkoordinaten-Punkten
/// im Bezugssystem des Raum-Scans, plus System und Nennweite.
/// Leitungen sind eigenständige Plandaten — sie verschwinden nicht,
/// wenn RoomPlan sie nicht als Objekt erkennt.
struct PipeRun: Codable, Identifiable {
    var id = UUID()
    var system: PipeSystem
    var diameter: NominalDiameter
    var points: [Vector3]
    var note: String = ""
    var createdAt = Date()

    var worldPoints: [SIMD3<Float>] { points.map(\.simd) }

    /// Gesamtlänge des Laufs in Metern.
    var length: Float {
        let pts = worldPoints
        return zip(pts, pts.dropFirst()).reduce(0) { $0 + simd_distance($1.0, $1.1) }
    }

    /// Segmente mit überwiegend senkrechtem Verlauf gelten als Steigleitung
    /// und werden im 2D-Plan als Symbol statt als Linie dargestellt.
    static func isVertical(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Bool {
        let d = simd_distance(a, b)
        guard d > 0.001 else { return false }
        return abs(b.y - a.y) > 0.7 * d
    }
}

/// Anlagen- und Sanitärobjekte, die als Punktmarker gesetzt werden.
enum EquipmentKind: String, Codable, CaseIterable, Identifiable {
    case heizkoerper
    case ventil
    case verteiler
    case pumpe
    case boiler
    case gastherme
    case waschbecken
    case wc
    case dusche
    case badewanne
    case spuele
    case wasserzaehler

    var id: String { rawValue }

    var label: String {
        switch self {
        case .heizkoerper: return "Heizkörper"
        case .ventil: return "Ventil"
        case .verteiler: return "Verteiler"
        case .pumpe: return "Pumpe"
        case .boiler: return "Speicher/Boiler"
        case .gastherme: return "Gastherme"
        case .waschbecken: return "Waschtisch"
        case .wc: return "WC"
        case .dusche: return "Dusche"
        case .badewanne: return "Badewanne"
        case .spuele: return "Spüle"
        case .wasserzaehler: return "Wasserzähler"
        }
    }

    /// Kurzcode für Plan- und DXF-Beschriftung.
    var planCode: String {
        switch self {
        case .heizkoerper: return "HK"
        case .ventil: return "V"
        case .verteiler: return "VT"
        case .pumpe: return "P"
        case .boiler: return "B"
        case .gastherme: return "GT"
        case .waschbecken: return "WT"
        case .wc: return "WC"
        case .dusche: return "DU"
        case .badewanne: return "BW"
        case .spuele: return "SP"
        case .wasserzaehler: return "WZ"
        }
    }

    var systemImage: String {
        switch self {
        case .heizkoerper: return "thermometer"
        case .ventil: return "circle.circle"
        case .verteiler: return "point.3.connected.trianglepath.dotted"
        case .pumpe: return "arrow.triangle.2.circlepath"
        case .boiler: return "cylinder"
        case .gastherme: return "flame"
        case .waschbecken: return "drop"
        case .wc: return "toilet"
        case .dusche: return "shower"
        case .badewanne: return "bathtub"
        case .spuele: return "sink"
        case .wasserzaehler: return "gauge"
        }
    }
}

struct Equipment: Codable, Identifiable {
    var id = UUID()
    var kind: EquipmentKind
    var position: Vector3
    var note: String = ""
}
