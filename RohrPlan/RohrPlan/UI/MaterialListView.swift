import SwiftUI

/// Materialliste aus den Scan-Daten: Rohrlängen je System und Nennweite
/// plus Stückliste der gesetzten Anlagenmarker.
struct MaterialListView: View {
    let project: ScanProject

    private struct DNRow: Identifiable {
        let dn: NominalDiameter
        let length: Float
        var id: Int { dn.rawValue }
    }

    private struct SystemGroup: Identifiable {
        let system: PipeSystem
        let rows: [DNRow]
        var id: String { system.rawValue }
    }

    private struct EquipmentRow: Identifiable {
        let kind: EquipmentKind
        let count: Int
        var id: String { kind.rawValue }
    }

    private var systemGroups: [SystemGroup] {
        PipeSystem.allCases.compactMap { system in
            let runs = project.pipes.filter { $0.system == system }
            guard !runs.isEmpty else { return nil }
            let rows = NominalDiameter.allCases.compactMap { dn -> DNRow? in
                let length = runs.filter { $0.diameter == dn }.reduce(Float(0)) { $0 + $1.length }
                return length > 0 ? DNRow(dn: dn, length: length) : nil
            }
            return SystemGroup(system: system, rows: rows)
        }
    }

    private var equipmentRows: [EquipmentRow] {
        EquipmentKind.allCases.compactMap { kind in
            let count = project.equipment.filter { $0.kind == kind }.count
            return count > 0 ? EquipmentRow(kind: kind, count: count) : nil
        }
    }

    var body: some View {
        if project.pipes.isEmpty && project.equipment.isEmpty {
            ContentUnavailableView("Keine Daten",
                                   systemImage: "list.bullet.rectangle",
                                   description: Text("Nach dem Scan erscheinen hier Rohrlängen und Stückliste."))
        } else {
            List {
                ForEach(systemGroups) { group in
                    Section {
                        ForEach(group.rows) { row in
                            HStack {
                                Text(row.dn.label)
                                Spacer()
                                Text(String(format: "%.2f m", row.length))
                                    .monospacedDigit()
                            }
                        }
                    } header: {
                        HStack(spacing: 8) {
                            Circle().fill(group.system.color).frame(width: 10, height: 10)
                            Text(group.system.label)
                        }
                    }
                }

                if !equipmentRows.isEmpty {
                    Section("Objekte") {
                        ForEach(equipmentRows) { row in
                            HStack {
                                Label(row.kind.label, systemImage: row.kind.systemImage)
                                Spacer()
                                Text("\(row.count) Stk").monospacedDigit()
                            }
                        }
                    }
                }

                Section {
                    HStack {
                        Text("Gesamtrohrlänge").bold()
                        Spacer()
                        Text(String(format: "%.2f m", project.totalPipeLength))
                            .bold()
                            .monospacedDigit()
                    }
                }
            }
        }
    }
}
