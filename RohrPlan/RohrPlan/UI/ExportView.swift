import SwiftUI
import UIKit

/// Export-Übersicht: erzeugt die Datei beim Antippen und öffnet das
/// System-Share-Sheet (AirDrop, Mail, Dateien, …).
struct ExportView: View {
    let project: ScanProject

    private struct ShareItem: Identifiable {
        let id = UUID()
        let url: URL
    }

    @State private var shareItem: ShareItem?
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section("Pläne & Modelle") {
                exportRow("2D-Plan als DXF",
                          detail: "Grundriss mit Leitungs-Layern für CAD/TGA-Software",
                          icon: "square.on.square.dashed") {
                    try ProjectExporter.dxf(project)
                }
                exportRow("3D-Modell als USDZ",
                          detail: "Parametrisches Raummodell aus dem RoomPlan-Scan",
                          icon: "cube") {
                    try ProjectExporter.usdz(project)
                }
            }
            Section("Daten") {
                exportRow("Materialliste als CSV",
                          detail: "Rohrlängen je System und Nennweite, Stückliste",
                          icon: "tablecells") {
                    try ProjectExporter.materialListCSV(project)
                }
                exportRow("Projekt als JSON",
                          detail: "Vollständige Rohdaten inkl. Leitungsgeometrie",
                          icon: "curlybraces.square") {
                    try ProjectExporter.json(project)
                }
            }
        }
        .sheet(item: $shareItem) { item in
            ActivityView(items: [item.url])
        }
        .alert("Export fehlgeschlagen",
               isPresented: Binding(get: { errorMessage != nil },
                                    set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func exportRow(_ title: String, detail: String, icon: String,
                           make: @escaping () throws -> URL) -> some View {
        Button {
            do {
                shareItem = ShareItem(url: try make())
            } catch {
                errorMessage = error.localizedDescription
            }
        } label: {
            HStack {
                Image(systemName: icon)
                    .font(.title3)
                    .frame(width: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(.primary)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "square.and.arrow.up")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
