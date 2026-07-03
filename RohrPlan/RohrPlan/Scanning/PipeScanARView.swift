import SwiftUI
import SceneKit
import ARKit

/// AR-Ansicht der Leitungsphase: übernimmt die laufende ARSession aus der
/// Raumphase (gleicher Weltursprung) und lässt den Nutzer per
/// LiDAR-Raycast Punkte entlang der Rohrleitungen setzen. Alle bereits
/// erfassten Läufe bleiben dauerhaft als 3D-Rohre eingeblendet.
struct PipeScanARView: UIViewRepresentable {
    @ObservedObject var scan: ScanCoordinator

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        view.session = scan.arSession
        view.scene = SCNScene()
        view.automaticallyUpdatesLighting = true

        // Ohne Reset-Optionen weiterlaufen lassen: Tracking und Weltursprung
        // aus der RoomPlan-Phase bleiben erhalten. Falls die Raumphase
        // übersprungen wurde, startet die Session hiermit frisch.
        let configuration = ARWorldTrackingConfiguration()
        configuration.planeDetection = [.horizontal, .vertical]
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            configuration.sceneReconstruction = .mesh
        }
        scan.arSession.run(configuration, options: [])

        context.coordinator.attach(view)
        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {
        context.coordinator.syncContent()
    }

    static func dismantleUIView(_ uiView: ARSCNView, coordinator: Coordinator) {
        coordinator.detach()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(scan: scan)
    }

    @MainActor
    final class Coordinator: NSObject {
        private let scan: ScanCoordinator
        private weak var view: ARSCNView?
        private var displayLink: CADisplayLink?

        private let runsNode = SCNNode()       // abgeschlossene Läufe
        private let currentNode = SCNNode()    // laufender Lauf
        private let equipmentNode = SCNNode()  // Anlagenmarker
        private let reticleNode: SCNNode
        private let previewNode = SCNNode()    // Linie letzter Punkt → Ziel

        private var drawnRunIDs: Set<UUID> = []
        private var drawnEquipmentIDs: Set<UUID> = []
        private var renderedPointCount = -1
        private var renderedSystem: PipeSystem?
        private var renderedDiameter: NominalDiameter?

        init(scan: ScanCoordinator) {
            self.scan = scan
            let sphere = SCNSphere(radius: 0.01)
            sphere.firstMaterial?.diffuse.contents = UIColor.white
            sphere.firstMaterial?.lightingModel = .constant
            reticleNode = SCNNode(geometry: sphere)
            reticleNode.isHidden = true
            super.init()
        }

        func attach(_ view: ARSCNView) {
            self.view = view
            for node in [runsNode, currentNode, equipmentNode, reticleNode, previewNode] {
                view.scene.rootNode.addChildNode(node)
            }
            let link = CADisplayLink(target: self, selector: #selector(tick))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
            link.add(to: .main, forMode: .common)
            displayLink = link
            syncContent()
        }

        func detach() {
            displayLink?.invalidate()
            displayLink = nil
        }

        // MARK: - Fadenkreuz & Vorschau (pro Frame)

        @objc private func tick() {
            guard let view else { return }
            let center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)

            guard let query = view.raycastQuery(from: center,
                                                allowing: .estimatedPlane,
                                                alignment: .any),
                  let hit = scan.arSession.raycast(query).first else {
                setTarget(nil)
                return
            }

            let t = hit.worldTransform.columns.3
            setTarget(SIMD3<Float>(t.x, t.y, t.z))
        }

        private func setTarget(_ target: SIMD3<Float>?) {
            scan.currentTarget = target

            guard let target else {
                reticleNode.isHidden = true
                previewNode.isHidden = true
                if scan.hasTarget { scan.hasTarget = false }
                if scan.reticleDistance != nil { scan.reticleDistance = nil }
                return
            }

            reticleNode.isHidden = false
            reticleNode.simdPosition = target
            reticleNode.geometry?.firstMaterial?.diffuse.contents = scan.activeSystem.uiColor
            if !scan.hasTarget { scan.hasTarget = true }

            if let camera = view?.pointOfView {
                let distance = simd_distance(camera.simdWorldPosition, target)
                // Nur bei sichtbarer Änderung publizieren (Text-Update in SwiftUI).
                if scan.reticleDistance.map({ abs($0 - distance) > 0.01 }) ?? true {
                    scan.reticleDistance = distance
                }
            }

            // Vorschau-Segment vom letzten gesetzten Punkt zum Ziel.
            if let last = scan.currentPoints.last {
                previewNode.isHidden = false
                previewNode.childNodes.forEach { $0.removeFromParentNode() }
                let segment = PipeNodeFactory.segmentNode(
                    from: last, to: target,
                    radius: CGFloat(scan.activeDiameter.displayRadius) * 0.6,
                    color: scan.activeSystem.uiColor.withAlphaComponent(0.5))
                previewNode.addChildNode(segment)
            } else {
                previewNode.isHidden = true
            }
        }

        // MARK: - Szeneninhalt (bei Modelländerung)

        func syncContent() {
            syncFinishedRuns()
            syncCurrentRun()
            syncEquipment()
        }

        private func syncFinishedRuns() {
            let ids = Set(scan.pipes.map(\.id))
            if ids == drawnRunIDs { return }

            for node in runsNode.childNodes
            where node.name.flatMap(UUID.init(uuidString:)).map({ !ids.contains($0) }) ?? true {
                node.removeFromParentNode()
            }
            for run in scan.pipes where !drawnRunIDs.contains(run.id) {
                let node = PipeNodeFactory.runNode(points: run.worldPoints,
                                                   system: run.system,
                                                   diameter: run.diameter)
                node.name = run.id.uuidString
                runsNode.addChildNode(node)
            }
            drawnRunIDs = ids
        }

        private func syncCurrentRun() {
            let unchanged = renderedPointCount == scan.currentPoints.count
                && renderedSystem == scan.activeSystem
                && renderedDiameter == scan.activeDiameter
            if unchanged { return }

            currentNode.childNodes.forEach { $0.removeFromParentNode() }
            let node = PipeNodeFactory.runNode(points: scan.currentPoints,
                                               system: scan.activeSystem,
                                               diameter: scan.activeDiameter)
            currentNode.addChildNode(node)

            renderedPointCount = scan.currentPoints.count
            renderedSystem = scan.activeSystem
            renderedDiameter = scan.activeDiameter
        }

        private func syncEquipment() {
            let ids = Set(scan.equipment.map(\.id))
            if ids == drawnEquipmentIDs { return }

            for node in equipmentNode.childNodes
            where node.name.flatMap(UUID.init(uuidString:)).map({ !ids.contains($0) }) ?? true {
                node.removeFromParentNode()
            }
            for item in scan.equipment where !drawnEquipmentIDs.contains(item.id) {
                let node = PipeNodeFactory.equipmentNode(item)
                node.name = item.id.uuidString
                equipmentNode.addChildNode(node)
            }
            drawnEquipmentIDs = ids
        }
    }
}
