import DBCore
import SwiftUI

struct StructureView: View {
    let structure: TableStructure

    var body: some View {
        VSplitView {
            section("Columns") {
                Table(structure.columns) {
                    TableColumn("#") { Text("\($0.position)").monospacedDigit().foregroundStyle(.secondary) }
                        .width(32)
                    TableColumn("Name") { column in
                        HStack(spacing: 4) {
                            if column.isPrimaryKey { Image(systemName: "key.fill").foregroundStyle(.yellow).imageScale(.small) }
                            Text(column.name)
                        }
                    }
                    TableColumn("Type") { Text($0.dataType).font(.body.monospaced()) }
                    TableColumn("Nullable") { Text($0.notNull ? "NOT NULL" : "NULL").foregroundStyle($0.notNull ? .primary : .secondary) }
                        .width(80)
                    TableColumn("Default") { column in
                        Text(column.isGenerated ? "GENERATED \(column.defaultExpression ?? "")" : column.isIdentity ? "IDENTITY" : column.defaultExpression ?? "")
                            .font(.body.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            section("Indexes") {
                Table(structure.indexes) {
                    TableColumn("Name") { index in
                        HStack(spacing: 4) {
                            if index.isPrimary { Image(systemName: "key.fill").foregroundStyle(.yellow).imageScale(.small) }
                            Text(index.name)
                        }
                    }
                    .width(ideal: 200)
                    TableColumn("Definition") { Text($0.definition).font(.body.monospaced()).textSelection(.enabled) }
                }
            }
            section("Constraints") {
                Table(structure.constraints) {
                    TableColumn("Name") { Text($0.name) }.width(ideal: 200)
                    TableColumn("Type") { Text($0.typeLabel) }.width(110)
                    TableColumn("Definition") { Text($0.definition).font(.body.monospaced()).textSelection(.enabled) }
                }
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.headline).padding(.horizontal).padding(.vertical, 8)
            content()
        }
        .frame(minHeight: 120)
    }
}
