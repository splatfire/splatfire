import Foundation
import RoomPlan

/// Erzeugt Export-Dateien im temporären Verzeichnis:
/// - DXF: 2D-Plan mit Layern je Gewerk (für CAD/TGA-Software)
/// - USDZ: parametrisches 3D-Modell aus dem RoomPlan-Scan
/// - CSV: Materialliste (Längen je System und Nennweite, Stückliste)
/// - JSON: vollständiges Projekt als offenes Datenformat
enum ProjectExporter {
    enum ExportError: LocalizedError {
        case noRoomScan

        var errorDescription: String? {
            switch self {
            case .noRoomScan:
                return "Für dieses Projekt liegt kein Raum-Scan vor — USDZ-Export nicht möglich."
            }
        }
    }

    private static func outputURL(for project: ScanProject, ext: String) -> URL {
        let safeName = project.name
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "_")
        let base = safeName.isEmpty ? "RohrPlan_Projekt" : safeName
        return FileManager.default.temporaryDirectory
            .appendingPathComponent(base)
            .appendingPathExtension(ext)
    }

    // MARK: - JSON

    static func json(_ project: ScanProject) throws -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(project)
        let url = outputURL(for: project, ext: "rohrplan.json")
        try data.write(to: url, options: .atomic)
        return url
    }

    // MARK: - USDZ

    static func usdz(_ project: ScanProject) throws -> URL {
        guard let data = project.capturedRoomData else {
            throw ExportError.noRoomScan
        }
        let room = try JSONDecoder().decode(CapturedRoom.self, from: data)
        let url = outputURL(for: project, ext: "usdz")
        try room.export(to: url, exportOptions: .parametric)
        return url
    }

    // MARK: - CSV-Materialliste

    static func materialListCSV(_ project: ScanProject) throws -> URL {
        var lines = ["Typ;System;Nennweite;Menge;Einheit"]

        var lengths: [String: Float] = [:]
        for run in project.pipes {
            let key = "\(run.system.rawValue)|\(run.diameter.rawValue)"
            lengths[key, default: 0] += run.length
        }
        for system in PipeSystem.allCases {
            for dn in NominalDiameter.allCases {
                guard let length = lengths["\(system.rawValue)|\(dn.rawValue)"] else { continue }
                lines.append("Rohr;\(system.label);\(dn.label);\(germanNumber(length));m")
            }
        }

        var counts: [EquipmentKind: Int] = [:]
        for item in project.equipment {
            counts[item.kind, default: 0] += 1
        }
        for kind in EquipmentKind.allCases {
            guard let count = counts[kind] else { continue }
            lines.append("Objekt;\(kind.label);;\(count);Stk")
        }

        let url = outputURL(for: project, ext: "csv")
        try lines.joined(separator: "\r\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static func germanNumber(_ value: Float) -> String {
        String(format: "%.2f", value).replacingOccurrences(of: ".", with: ",")
    }

    // MARK: - DXF (2D-Plan)

    static func dxf(_ project: ScanProject) throws -> URL {
        let model = FloorPlanModel(project: project)
        var out = DXFWriter()

        out.beginLayerTable()
        out.layer(name: "WAENDE", color: 7)
        out.layer(name: "TUEREN", color: 34)
        out.layer(name: "FENSTER", color: 4)
        out.layer(name: "OEFFNUNGEN", color: 8)
        out.layer(name: "OBJEKTE", color: 9)
        for system in PipeSystem.allCases {
            out.layer(name: system.dxfLayer, color: system.dxfColorIndex)
        }
        out.endLayerTable()

        out.beginEntities()
        for wall in model.walls { out.line(wall, layer: "WAENDE") }
        for door in model.doors { out.line(door, layer: "TUEREN") }
        for window in model.windows { out.line(window, layer: "FENSTER") }
        for opening in model.openings { out.line(opening, layer: "OEFFNUNGEN") }

        for pipe in model.pipes {
            for (a, b) in zip(pipe.points, pipe.points.dropFirst()) {
                out.line(FloorPlanModel.Segment(a: a, b: b), layer: pipe.system.dxfLayer)
            }
            if pipe.points.count >= 2 {
                let mid = pipe.points[pipe.points.count / 2]
                out.text("\(pipe.system.shortCode) \(pipe.diameter.label)",
                         at: mid, height: 0.1, layer: pipe.system.dxfLayer)
            }
        }
        for riser in model.risers {
            out.circle(at: riser.at, radius: 0.06, layer: riser.system.dxfLayer)
            out.text(riser.goesUp ? "STG-AUF" : "STG-AB",
                     at: CGPoint(x: riser.at.x + 0.1, y: riser.at.y),
                     height: 0.08, layer: riser.system.dxfLayer)
        }
        for marker in model.markers {
            out.circle(at: marker.at, radius: 0.09, layer: "OBJEKTE")
            out.text(marker.kind.planCode,
                     at: CGPoint(x: marker.at.x + 0.12, y: marker.at.y),
                     height: 0.08, layer: "OBJEKTE")
        }
        out.endEntities()

        let url = outputURL(for: project, ext: "dxf")
        try out.finish().write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

/// Minimaler DXF-R12-Schreiber. Koordinaten in Millimetern; die y-Achse wird
/// gespiegelt, damit der Plan in CAD lagerichtig erscheint (Bildschirm-y
/// zeigt nach unten, CAD-y nach oben). Alle Linientypen sind CONTINUOUS —
/// die Gewerke-Unterscheidung erfolgt über Layer und Farbe.
private struct DXFWriter {
    private var body = ""

    private func mm(_ v: CGFloat) -> String {
        String(format: "%.1f", v * 1000)
    }

    mutating func beginLayerTable() {
        body += "0\nSECTION\n2\nTABLES\n0\nTABLE\n2\nLAYER\n70\n20\n"
        layer(name: "0", color: 7)
    }

    mutating func layer(name: String, color: Int) {
        body += "0\nLAYER\n2\n\(name)\n70\n0\n62\n\(color)\n6\nCONTINUOUS\n"
    }

    mutating func endLayerTable() {
        body += "0\nENDTAB\n0\nENDSEC\n"
    }

    mutating func beginEntities() {
        body += "0\nSECTION\n2\nENTITIES\n"
    }

    mutating func line(_ segment: FloorPlanModel.Segment, layer: String) {
        body += "0\nLINE\n8\n\(layer)\n"
        body += "10\n\(mm(segment.a.x))\n20\n\(mm(-segment.a.y))\n30\n0.0\n"
        body += "11\n\(mm(segment.b.x))\n21\n\(mm(-segment.b.y))\n31\n0.0\n"
    }

    mutating func circle(at center: CGPoint, radius: CGFloat, layer: String) {
        body += "0\nCIRCLE\n8\n\(layer)\n"
        body += "10\n\(mm(center.x))\n20\n\(mm(-center.y))\n30\n0.0\n40\n\(mm(radius))\n"
    }

    mutating func text(_ string: String, at position: CGPoint, height: CGFloat, layer: String) {
        body += "0\nTEXT\n8\n\(layer)\n"
        body += "10\n\(mm(position.x))\n20\n\(mm(-position.y))\n30\n0.0\n"
        body += "40\n\(mm(height))\n1\n\(string)\n"
    }

    mutating func endEntities() {
        body += "0\nENDSEC\n"
    }

    func finish() -> String {
        body + "0\nEOF\n"
    }
}
