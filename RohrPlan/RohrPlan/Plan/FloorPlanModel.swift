import CoreGraphics
import simd

/// Projiziert Raumhülle, Leitungen und Marker eines Projekts in ein
/// 2D-Grundriss-Modell (Draufsicht, Koordinaten in Metern). Der Plan wird
/// automatisch so gedreht, dass die dominante Wandrichtung achsparallel liegt.
struct FloorPlanModel {
    struct Segment {
        var a: CGPoint
        var b: CGPoint
    }

    struct PipePath {
        var system: PipeSystem
        var diameter: NominalDiameter
        var points: [CGPoint]
    }

    struct Riser {
        var system: PipeSystem
        var at: CGPoint
        var goesUp: Bool
    }

    struct Marker {
        var kind: EquipmentKind
        var at: CGPoint
    }

    var walls: [Segment] = []
    var doors: [Segment] = []
    var windows: [Segment] = []
    var openings: [Segment] = []
    var objects: [Segment] = []
    var pipes: [PipePath] = []
    var risers: [Riser] = []
    var markers: [Marker] = []
    var bounds: CGRect = .zero

    var isEmpty: Bool {
        walls.isEmpty && pipes.isEmpty && risers.isEmpty && markers.isEmpty
    }

    /// Systeme, die im Plan vorkommen — für die Legende.
    var usedSystems: [PipeSystem] {
        var seen: Set<PipeSystem> = []
        var ordered: [PipeSystem] = []
        for system in pipes.map(\.system) + risers.map(\.system) where seen.insert(system).inserted {
            ordered.append(system)
        }
        return ordered
    }

    init(project: ScanProject) {
        let rotation = -Self.dominantWallAngle(project.room)
        let cosA = cos(rotation)
        let sinA = sin(rotation)

        func flatten(_ v: SIMD3<Float>) -> CGPoint {
            let x = CGFloat(v.x)
            let z = CGFloat(v.z)
            return CGPoint(x: x * cosA - z * sinA, y: x * sinA + z * cosA)
        }

        func surfaceSegment(_ surface: PlanSurface) -> Segment {
            let center = surface.transform.translation
            let half = surface.transform.xAxis * (surface.dimensions.simd.x / 2)
            return Segment(a: flatten(center - half), b: flatten(center + half))
        }

        walls = project.room.walls.map(surfaceSegment)
        doors = project.room.doors.map(surfaceSegment)
        windows = project.room.windows.map(surfaceSegment)
        openings = project.room.openings.map(surfaceSegment)

        // Möbelobjekte als Diagonale ihrer Grundfläche (nur Orientierungshilfe).
        objects = project.room.objects.map { object in
            let center = object.transform.translation
            let half = object.transform.xAxis * (object.dimensions.simd.x / 2)
            return Segment(a: flatten(center - half), b: flatten(center + half))
        }

        for run in project.pipes {
            appendRun(run, flatten: flatten)
        }

        markers = project.equipment.map {
            Marker(kind: $0.kind, at: flatten($0.position.simd))
        }

        bounds = Self.computeBounds(of: self)
    }

    /// Zerlegt einen Leitungslauf in horizontale Teil-Polylinien und
    /// Steigleitungs-Symbole (senkrechte Segmente).
    private mutating func appendRun(_ run: PipeRun, flatten: (SIMD3<Float>) -> CGPoint) {
        let pts = run.worldPoints
        guard pts.count >= 2 else { return }

        var current: [CGPoint] = []

        func flush() {
            if current.count >= 2 {
                pipes.append(PipePath(system: run.system, diameter: run.diameter, points: current))
            }
            current = []
        }

        for (a, b) in zip(pts, pts.dropFirst()) {
            if PipeRun.isVertical(a, b) {
                if current.isEmpty { current.append(flatten(a)) }
                flush()
                risers.append(Riser(system: run.system,
                                    at: flatten((a + b) / 2),
                                    goesUp: b.y > a.y))
                current = [flatten(b)]
            } else {
                if current.isEmpty { current.append(flatten(a)) }
                current.append(flatten(b))
            }
        }
        flush()
    }

    // MARK: - Hilfen

    /// Längengewichtete dominante Wandrichtung, modulo 90°, über die
    /// Winkelverdopplungs-Methode (Summe von e^{i·4θ}).
    private static func dominantWallAngle(_ room: RoomShell) -> CGFloat {
        var sumX: CGFloat = 0
        var sumY: CGFloat = 0
        for wall in room.walls {
            let axis = wall.transform.xAxis
            let length = CGFloat(wall.dimensions.x)
            let theta = CGFloat(atan2(axis.z, axis.x))
            sumX += length * cos(4 * theta)
            sumY += length * sin(4 * theta)
        }
        guard sumX != 0 || sumY != 0 else { return 0 }
        return atan2(sumY, sumX) / 4
    }

    private static func computeBounds(of model: FloorPlanModel) -> CGRect {
        var points: [CGPoint] = []
        for segment in model.walls + model.doors + model.windows + model.openings {
            points.append(segment.a)
            points.append(segment.b)
        }
        points += model.pipes.flatMap(\.points)
        points += model.risers.map(\.at)
        points += model.markers.map(\.at)

        guard let first = points.first else { return .zero }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in points {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        let margin: CGFloat = 0.5
        return CGRect(x: minX - margin,
                      y: minY - margin,
                      width: max(maxX - minX + 2 * margin, 0.1),
                      height: max(maxY - minY + 2 * margin, 0.1))
    }
}
