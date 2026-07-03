import SwiftUI
import SceneKit

/// Interaktives 3D-Modell: halbtransparente Raumhülle plus alle Leitungen
/// als farbige Rohre und Anlagenmarker — frei drehbar (Orbit-Kamera).
struct Model3DView: UIViewRepresentable {
    let project: ScanProject

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = Self.buildScene(project: project)
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = true
        view.backgroundColor = .systemBackground
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        uiView.scene = Self.buildScene(project: project)
    }

    static func buildScene(project: ScanProject) -> SCNScene {
        let scene = SCNScene()
        let root = scene.rootNode

        for surface in project.room.surfaces {
            root.addChildNode(surfaceNode(surface))
        }
        for object in project.room.objects {
            root.addChildNode(objectNode(object))
        }
        for run in project.pipes {
            root.addChildNode(PipeNodeFactory.runNode(points: run.worldPoints,
                                                      system: run.system,
                                                      diameter: run.diameter))
        }
        for item in project.equipment {
            root.addChildNode(PipeNodeFactory.equipmentNode(item))
        }
        return scene
    }

    private static func surfaceNode(_ surface: PlanSurface) -> SCNNode {
        let dims = surface.dimensions.simd
        let color: UIColor
        let alpha: CGFloat
        switch surface.kind {
        case .wall:
            color = .systemGray; alpha = 0.30
        case .door:
            color = .systemBrown; alpha = 0.45
        case .window:
            color = .systemBlue; alpha = 0.35
        case .opening:
            color = .systemGray2; alpha = 0.15
        }

        let box = SCNBox(width: CGFloat(max(dims.x, 0.01)),
                         height: CGFloat(max(dims.y, 0.01)),
                         length: CGFloat(max(dims.z, 0.06)),
                         chamferRadius: 0)
        let material = SCNMaterial()
        material.diffuse.contents = color.withAlphaComponent(alpha)
        material.isDoubleSided = true
        box.firstMaterial = material

        let node = SCNNode(geometry: box)
        node.simdTransform = surface.transform.simd
        return node
    }

    private static func objectNode(_ object: PlanObject) -> SCNNode {
        let dims = object.dimensions.simd
        let box = SCNBox(width: CGFloat(max(dims.x, 0.01)),
                         height: CGFloat(max(dims.y, 0.01)),
                         length: CGFloat(max(dims.z, 0.01)),
                         chamferRadius: 0.01)
        let material = SCNMaterial()
        material.diffuse.contents = UIColor.systemGray4.withAlphaComponent(0.2)
        box.firstMaterial = material

        let node = SCNNode(geometry: box)
        node.simdTransform = object.transform.simd
        return node
    }
}
