import SwiftUI

struct ProjectDetailView: View {
    @EnvironmentObject private var store: ProjectStore
    let projectID: UUID

    private enum Tab: String, CaseIterable, Identifiable {
        case plan = "Plan"
        case model = "3D"
        case material = "Material"
        case export = "Export"

        var id: String { rawValue }
    }

    @State private var tab: Tab = .plan
    @State private var showScanFlow = false

    var body: some View {
        if let project = store.project(id: projectID) {
            VStack(spacing: 0) {
                Picker("Ansicht", selection: $tab) {
                    ForEach(Tab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)

                switch tab {
                case .plan:
                    FloorPlanView(project: project)
                case .model:
                    if project.hasScanData {
                        Model3DView(project: project)
                    } else {
                        noScanPlaceholder
                    }
                case .material:
                    MaterialListView(project: project)
                case .export:
                    ExportView(project: project)
                }
            }
            .navigationTitle(project.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showScanFlow = true
                    } label: {
                        Label(project.hasScanData ? "Neu scannen" : "Scan starten",
                              systemImage: "camera.metering.matrix")
                    }
                }
            }
            .fullScreenCover(isPresented: $showScanFlow) {
                ScanFlowView(project: project) { _ in }
                    .environmentObject(store)
            }
        } else {
            ContentUnavailableView("Projekt nicht gefunden", systemImage: "questionmark.folder")
        }
    }

    private var noScanPlaceholder: some View {
        ContentUnavailableView {
            Label("Noch kein Scan", systemImage: "cube.transparent")
        } description: {
            Text("Starte einen Scan, um Raum und Leitungen in 3D zu sehen.")
        } actions: {
            Button("Scan starten") { showScanFlow = true }
                .buttonStyle(.borderedProminent)
        }
    }
}
