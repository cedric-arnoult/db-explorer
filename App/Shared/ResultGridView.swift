import DBCore
import SwiftUI

/// Read-only grid for arbitrary query results.
struct ResultGridView: View {
    let resultSet: ResultSet
    @State private var selection: Set<Int> = []

    var body: some View {
        if resultSet.columns.isEmpty {
            ContentUnavailableView("No Results", systemImage: "tablecells",
                                   description: Text("The last statement did not return rows."))
        } else {
            Table(resultSet.rows, selection: $selection) {
                TableColumnForEach(resultSet.columns) { column in
                    TableColumn(column.name) { row in
                        CellText(value: row[column.index])
                    }
                    .width(min: 50, ideal: 140)
                    .customizationID(column.name)
                }
            }
            .font(.body.monospaced())
            .copyable(selectedRows.map(\.tsv))
            .contextMenu(forSelectionType: Int.self) { ids in
                Button("Copy") { copy(ids) }
            }
        }
    }

    private var selectedRows: [ResultRow] {
        resultSet.rows.filter { selection.contains($0.id) }
    }

    private func copy(_ ids: Set<Int>) {
        let text = resultSet.rows.filter { ids.contains($0.id) }.map(\.tsv).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

extension ResultRow {
    /// Tab-separated values, for copying.
    var tsv: String {
        values.map { $0.isNull ? "" : $0.displayString }.joined(separator: "\t")
    }
}
