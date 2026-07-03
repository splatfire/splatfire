import SwiftUI

/// 2D-Grundriss mit Wänden, Türen, Fenstern — und allen Leitungen,
/// farbcodiert nach System, mit Steigleitungs-Symbolen, DN-Beschriftung,
/// Legende und Maßstabsbalken. Zoom per Pinch, Verschieben per Drag.
struct FloorPlanView: View {
    let project: ScanProject

    private let model: FloorPlanModel

    @State private var zoom: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1
    @State private var pan: CGSize = .zero
    @GestureState private var drag: CGSize = .zero

    init(project: ScanProject) {
        self.project = project
        self.model = FloorPlanModel(project: project)
    }

    var body: some View {
        if model.isEmpty {
            ContentUnavailableView("Noch kein Scan",
                                   systemImage: "square.dashed",
                                   description: Text("Starte einen Scan, um den Grundriss mit Leitungen zu sehen."))
        } else {
            GeometryReader { geo in
                let scale = fitScale(in: geo.size) * zoom * pinch
                let offset = CGSize(width: pan.width + drag.width,
                                    height: pan.height + drag.height)

                ZStack(alignment: .bottomLeading) {
                    Canvas { context, size in
                        draw(in: &context, size: size, scale: scale, offset: offset)
                    }
                    .background(Color(.systemBackground))

                    VStack(alignment: .leading, spacing: 8) {
                        legend
                        scaleBar(scale: scale)
                    }
                    .padding(12)
                }
                .contentShape(Rectangle())
                .gesture(
                    MagnificationGesture()
                        .updating($pinch) { value, state, _ in state = value }
                        .onEnded { value in
                            zoom = min(max(zoom * value, 0.3), 12)
                        }
                        .simultaneously(with:
                            DragGesture()
                                .updating($drag) { value, state, _ in state = value.translation }
                                .onEnded { value in
                                    pan.width += value.translation.width
                                    pan.height += value.translation.height
                                }
                        )
                )
            }
        }
    }

    // MARK: - Zeichnen

    private func fitScale(in size: CGSize) -> CGFloat {
        guard model.bounds.width > 0, model.bounds.height > 0 else { return 50 }
        return min((size.width - 40) / model.bounds.width,
                   (size.height - 40) / model.bounds.height)
    }

    private func draw(in context: inout GraphicsContext, size: CGSize,
                      scale: CGFloat, offset: CGSize) {
        let center = CGPoint(x: model.bounds.midX, y: model.bounds.midY)

        func toScreen(_ p: CGPoint) -> CGPoint {
            CGPoint(x: (p.x - center.x) * scale + size.width / 2 + offset.width,
                    y: (p.y - center.y) * scale + size.height / 2 + offset.height)
        }

        func path(for segment: FloorPlanModel.Segment) -> Path {
            var p = Path()
            p.move(to: toScreen(segment.a))
            p.addLine(to: toScreen(segment.b))
            return p
        }

        // Möbel als dünne Hilfslinien
        for object in model.objects {
            context.stroke(path(for: object), with: .color(.gray.opacity(0.25)),
                           style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }

        // Wände
        let wallWidth = max(0.12 * scale, 3)
        for wall in model.walls {
            context.stroke(path(for: wall), with: .color(.primary.opacity(0.85)),
                           style: StrokeStyle(lineWidth: wallWidth, lineCap: .butt))
        }

        // Öffnungen: Wandlücke
        for opening in model.openings {
            context.stroke(path(for: opening), with: .color(Color(.systemBackground)),
                           style: StrokeStyle(lineWidth: wallWidth + 1))
        }

        // Türen: Lücke + braune Linie
        for door in model.doors {
            context.stroke(path(for: door), with: .color(Color(.systemBackground)),
                           style: StrokeStyle(lineWidth: wallWidth + 1))
            context.stroke(path(for: door), with: .color(.brown),
                           style: StrokeStyle(lineWidth: 2))
        }

        // Fenster: Lücke + doppelte blaue Linie
        for window in model.windows {
            context.stroke(path(for: window), with: .color(Color(.systemBackground)),
                           style: StrokeStyle(lineWidth: wallWidth + 1))
            for offsetSign: CGFloat in [-1, 1] {
                let a = toScreen(window.a)
                let b = toScreen(window.b)
                let dx = b.x - a.x, dy = b.y - a.y
                let len = max(sqrt(dx * dx + dy * dy), 0.001)
                let nx = -dy / len * 2 * offsetSign
                let ny = dx / len * 2 * offsetSign
                var p = Path()
                p.move(to: CGPoint(x: a.x + nx, y: a.y + ny))
                p.addLine(to: CGPoint(x: b.x + nx, y: b.y + ny))
                context.stroke(p, with: .color(.blue.opacity(0.8)),
                               style: StrokeStyle(lineWidth: 1.5))
            }
        }

        // Leitungen — das Herzstück: bleiben dauerhaft im Plan sichtbar.
        for pipe in model.pipes {
            var p = Path()
            let screenPoints = pipe.points.map(toScreen)
            guard let first = screenPoints.first else { continue }
            p.move(to: first)
            for point in screenPoints.dropFirst() {
                p.addLine(to: point)
            }
            let style = StrokeStyle(lineWidth: pipe.diameter.planLineWidth,
                                    lineCap: .round, lineJoin: .round,
                                    dash: pipe.system.dashed ? [7, 5] : [])
            context.stroke(p, with: .color(pipe.system.color), style: style)

            // Beschriftung am Mittelpunkt der Polylinie
            if screenPoints.count >= 2 {
                let mid = screenPoints[screenPoints.count / 2]
                let label = Text("\(pipe.system.shortCode) \(pipe.diameter.label)")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(pipe.system.color)
                context.draw(context.resolve(label),
                             at: CGPoint(x: mid.x, y: mid.y - 10))
            }
        }

        // Steigleitungen: Kreis + Richtungsdreieck
        for riser in model.risers {
            let at = toScreen(riser.at)
            let radius: CGFloat = 7
            let circle = Path(ellipseIn: CGRect(x: at.x - radius, y: at.y - radius,
                                                width: 2 * radius, height: 2 * radius))
            context.fill(circle, with: .color(Color(.systemBackground)))
            context.stroke(circle, with: .color(riser.system.color),
                           style: StrokeStyle(lineWidth: 2))
            let arrow = Text(riser.goesUp ? "▲" : "▼")
                .font(.system(size: 8))
                .foregroundStyle(riser.system.color)
            context.draw(context.resolve(arrow), at: at)
        }

        // Anlagenmarker
        for marker in model.markers {
            let at = toScreen(marker.at)
            let radius: CGFloat = 9
            let circle = Path(ellipseIn: CGRect(x: at.x - radius, y: at.y - radius,
                                                width: 2 * radius, height: 2 * radius))
            context.fill(circle, with: .color(Color(.systemBackground)))
            context.stroke(circle, with: .color(.primary), style: StrokeStyle(lineWidth: 1.5))
            let code = Text(marker.kind.planCode)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.primary)
            context.draw(context.resolve(code), at: at)
        }
    }

    // MARK: - Legende & Maßstab

    private var legend: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(model.usedSystems) { system in
                HStack(spacing: 6) {
                    Rectangle()
                        .fill(system.color)
                        .frame(width: 18, height: 3)
                        .overlay {
                            if system.dashed {
                                Rectangle()
                                    .fill(Color(.systemBackground))
                                    .frame(width: 4, height: 3)
                            }
                        }
                    Text("\(system.label) · \(formatLength(totalLength(of: system)))")
                        .font(.caption2)
                }
            }
        }
        .padding(8)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private func scaleBar(scale: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Rectangle()
                .frame(width: scale, height: 3)
            Text("1 m").font(.caption2)
        }
        .padding(6)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 6))
    }

    private func totalLength(of system: PipeSystem) -> Float {
        project.pipes.filter { $0.system == system }.reduce(0) { $0 + $1.length }
    }

    private func formatLength(_ meters: Float) -> String {
        String(format: "%.1f m", meters)
    }
}
