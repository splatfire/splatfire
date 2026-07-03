import SwiftUI

struct ProjectListView: View {
    @EnvironmentObject private var store: ProjectStore
    @State private var newProjectName = ""
    @State private var showNewProjectAlert = false
    @State private var path: [UUID] = []

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if store.projects.isEmpty {
                    ContentUnavailableView {
                        Label("Keine Projekte", systemImage: "pipe.and.drop")
                    } description: {
                        Text("Lege ein Projekt an und scanne Raum und Rohrleitungen mit dem LiDAR-Scanner.")
                    } actions: {
                        Button("Neues Projekt") { showNewProjectAlert = true }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    List {
                        if !ScanCoordinator.isRoomScanSupported {
                            Label("Dieses Gerät hat keinen LiDAR-Scanner — Raum-Scans sind nicht verfügbar.",
                                  systemImage: "exclamationmark.triangle")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(store.projects) { project in
                            NavigationLink(value: project.id) {
                                row(for: project)
                            }
                        }
                        .onDelete { offsets in
                            let doomed = offsets.map { store.projects[$0] }
                            doomed.forEach(store.delete)
                        }
                    }
                }
            }
            .navigationTitle("RohrPlan")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showNewProjectAlert = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .navigationDestination(for: UUID.self) { id in
                ProjectDetailView(projectID: id)
            }
            .alert("Neues Projekt", isPresented: $showNewProjectAlert) {
                TextField("Projektname", text: $newProjectName)
                Button("Anlegen") { createProject() }
                Button("Abbrechen", role: .cancel) { newProjectName = "" }
            } message: {
                Text("z. B. Kunde, Objekt oder Baustelle")
            }
        }
    }

    private func row(for project: ScanProject) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(project.name).font(.headline)
            HStack(spacing: 12) {
                Label(project.updatedAt.formatted(date: .abbreviated, time: .shortened),
                      systemImage: "clock")
                if !project.pipes.isEmpty {
                    Label("\(project.pipes.count) Läufe · \(String(format: "%.1f m", project.totalPipeLength))",
                          systemImage: "pipe.and.drop")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func createProject() {
        let name = newProjectName.trimmingCharacters(in: .whitespacesAndNewlines)
        let project = ScanProject(name: name.isEmpty ? "Neues Projekt" : name)
        store.save(project)
        newProjectName = ""
        path.append(project.id)
    }
}
