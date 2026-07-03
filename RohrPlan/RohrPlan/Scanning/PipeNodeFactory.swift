import SceneKit
import UIKit
import simd

/// Baut SceneKit-Knoten für Leitungsläufe und Anlagenmarker.
/// Wird sowohl in der AR-Leitungsphase als auch im 3D-Viewer verwendet,
/// damit beide dieselbe Darstellung zeigen.
enum PipeNodeFactory {

    static func runNode(points: [SIMD3<Float>],
                        system: PipeSystem,
                        diameter: NominalDiameter) -> SCNNode {
        let parent = SCNNode()
        let radius = CGFloat(diameter.displayRadius)
        let color = system.uiColor

        for point in points {
            parent.addChildNode(jointNode(at: point, radius: radius * 1.25, color: color))
        }
        for (a, b) in zip(points, points.dropFirst()) {
            parent.addChildNode(segmentNode(from: a, to: b, radius: radius, color: color))
        }
        return parent
    }

    static func jointNode(at position: SIMD3<Float>,
                          radius: CGFloat,
                          color: UIColor) -> SCNNode {
        let sphere = SCNSphere(radius: radius)
        sphere.firstMaterial = material(color: color)
        let node = SCNNode(geometry: sphere)
        node.simdPosition = position
        return node
    }

    static func segmentNode(from a: SIMD3<Float>,
                            to b: SIMD3<Float>,
                            radius: CGFloat,
                            color: UIColor) -> SCNNode {
        let distance = simd_distance(a, b)
        let cylinder = SCNCylinder(radius: radius, height: CGFloat(max(distance, 0.001)))
        cylinder.firstMaterial = material(color: color)

        let node = SCNNode(geometry: cylinder)
        node.simdPosition = (a + b) / 2
        node.simdOrientation = orientation(from: a, to: b)
        return node
    }

    static func equipmentNode(_ equipment: Equipment) -> SCNNode {
        let parent = SCNNode()
        parent.simdPosition = equipment.position.simd

        let sphere = SCNSphere(radius: 0.035)
        sphere.firstMaterial = material(color: .white)
        parent.addChildNode(SCNNode(geometry: sphere))

        let text = SCNText(string: equipment.kind.planCode, extrusionDepth: 0.5)
        text.font = UIFont.boldSystemFont(ofSize: 10)
        text.firstMaterial = material(color: .white)
        text.flatness = 0.3

        let textNode = SCNNode(geometry: text)
        textNode.scale = SCNVector3(0.008, 0.008, 0.008)
        // Text über dem Marker zentrieren und zur Kamera drehen.
        let (min, max) = textNode.boundingBox
        textNode.pivot = SCNMatrix4MakeTranslation((max.x + min.x) / 2, min.y, 0)
        textNode.position = SCNVector3(0, 0.06, 0)
        textNode.constraints = [SCNBillboardConstraint()]
        parent.addChildNode(textNode)

        return parent
    }

    private static func material(color: UIColor) -> SCNMaterial {
        let material = SCNMaterial()
        material.diffuse.contents = color
        material.emission.contents = color.withAlphaComponent(0.35)
        material.lightingModel = .constant
        return material
    }

    /// Quaternion, das die y-Achse eines Zylinders auf die Richtung a→b dreht.
    private static func orientation(from a: SIMD3<Float>, to b: SIMD3<Float>) -> simd_quatf {
        let up = SIMD3<Float>(0, 1, 0)
        let delta = b - a
        let length = simd_length(delta)
        guard length > 0.0001 else { return simd_quatf(angle: 0, axis: up) }
        let direction = delta / length

        let dot = simd_dot(up, direction)
        if dot > 0.9999 {
            return simd_quatf(angle: 0, axis: up)
        }
        if dot < -0.9999 {
            return simd_quatf(angle: .pi, axis: SIMD3<Float>(1, 0, 0))
        }
        return simd_quatf(from: up, to: direction)
    }
}
