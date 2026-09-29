import DBCore
import SwiftUI

/// Form editing one row: one field per column, with NULL / DEFAULT toggles.
struct RowInspector: View {
    @Bindable var model: TableDataModel

    var body: some View {
        if model.selection.count == 1, let id = model.selection.first, let row = model.gridRow(id: id) {
            Form {
                Section {
                    ForEach(Array(model.columns.enumerated()), id: \.offset) { index, column in
                        FieldEditor(
                            column: column,
                            value: row[index],
                            isNewRow: row.state == .inserted,
                            isEditable: model.isEditable && column.isWritable && row.state != .deleted,
                            isModified: row.modifiedColumns.contains(index)
                        ) { newValue in
                            model.setValue(newValue, rowID: id, column: index)
                        }
                        .id("\(id)-\(index)")
                    }
                } header: {
                    HStack {
                        Text(row.state == .inserted ? "New Row" : "Row")
                        Spacer()
                        if row.state == .deleted {
                            Text("Deleted").foregroundStyle(.red)
                        }
                    }
                }
            }
            .formStyle(.grouped)
        } else {
            ContentUnavailableView(
                model.selection.isEmpty ? "No Row Selected" : "\(model.selection.count) Rows Selected",
                systemImage: "sidebar.right",
                description: Text("Select a single row to inspect or edit it."))
        }
    }
}

private struct FieldEditor: View {
    let column: ColumnInfo
    let value: CellValue
    let isNewRow: Bool
    let isEditable: Bool
    let isModified: Bool
    let commit: (CellValue) -> Void

    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                if column.isPrimaryKey { Image(systemName: "key.fill").foregroundStyle(.yellow).imageScale(.small) }
                Text(column.name).fontWeight(.medium)
                if isModified { Circle().fill(.orange).frame(width: 6, height: 6) }
                Spacer()
                Text(column.dataType).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            HStack(alignment: .top) {
                TextField(column.name, text: $draft, prompt: Text(placeholder), axis: .vertical)
                    .labelsHidden()
                    .font(.body.monospaced())
                    .lineLimit(1...8)
                    .disabled(!isEditable || value == .null || value == .default)
                    .focused($focused)
                    .onSubmit(commitDraft)
                    .onChange(of: focused) { _, isFocused in if !isFocused { commitDraft() } }
                if isEditable {
                    Menu {
                        Button("Set NULL") { commit(.null) }.disabled(column.notNull)
                        Button("Set Empty String") { commit(.text("")) }
                        if isNewRow || column.defaultExpression != nil {
                            Button("Use DEFAULT") { commit(.default) }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .fixedSize()
                }
            }
        }
        .onAppear { draft = value.text ?? "" }
        .onChange(of: value) { _, newValue in draft = newValue.text ?? "" }
    }

    private var placeholder: String {
        switch value {
        case .null: "NULL — use ⋯ to set a value"
        case .default: column.defaultExpression.map { "DEFAULT \($0)" } ?? "DEFAULT"
        case .text: ""
        }
    }

    private func commitDraft() {
        guard isEditable, case .text(let current) = value, draft != current else { return }
        commit(.text(draft))
    }
}
