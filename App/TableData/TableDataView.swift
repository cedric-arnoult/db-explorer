import DBCore
import SwiftUI

struct TableDataView: View {
    @Bindable var model: TableDataModel
    @State private var sortOrder: [ColumnSort<GridRow>] = []
    @State private var showInspector = true

    private var indexedColumns: [IndexedColumn] {
        model.columns.enumerated().map { IndexedColumn(index: $0.offset, column: $0.element) }
    }

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            grid
            Divider()
            statusBar
        }
        .inspector(isPresented: $showInspector) {
            RowInspector(model: model)
                .inspectorColumnWidth(min: 260, ideal: 320, max: 520)
        }
        .onChange(of: sortOrder) { _, newValue in
            let descriptor = newValue.first.map {
                DBCore.SortDescriptor(column: model.columns[$0.column].name, ascending: $0.order == .forward)
            }
            Task { await model.setSort(descriptor) }
        }
    }

    private var filterBar: some View {
        HStack {
            Image(systemName: "line.3.horizontal.decrease").foregroundStyle(.secondary)
            TextField("WHERE clause, e.g. name ILIKE 'a%' AND id > 10", text: $model.filterDraft)
                .textFieldStyle(.plain)
                .font(.body.monospaced())
                .onSubmit { Task { await model.applyFilter() } }
            if !model.filterDraft.isEmpty {
                Button("Clear", systemImage: "xmark.circle.fill") {
                    model.filterDraft = ""
                    Task { await model.applyFilter() }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            Button("Apply") { Task { await model.applyFilter() } }
                .buttonStyle(.glass)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var grid: some View {
        Table(model.gridRows, selection: $model.selection, sortOrder: $sortOrder) {
            TableColumnForEach(indexedColumns) { item in
                TableColumn(item.column.name, sortUsing: ColumnSort<GridRow>(column: item.index)) { row in
                    GridCell(row: row, column: item.index)
                }
                .width(min: 50, ideal: 140)
                .customizationID(item.column.name)
            }
        }
        .font(.body.monospaced())
        .contextMenu(forSelectionType: Int.self) { ids in
            Button("Copy") { copy(ids) }
            if model.isEditable {
                Divider()
                Button("Add Row") { model.addRow() }
                if ids.contains(where: { model.gridRow(id: $0)?.state == .deleted }) {
                    Button("Restore Row") { model.selection = ids; model.restoreSelected() }
                } else {
                    Button("Delete Row", role: .destructive) { model.selection = ids; model.deleteSelected() }
                }
            }
        } primaryAction: { ids in
            model.selection = ids
            showInspector = true
        }
        .copyable(model.gridRows.filter { model.selection.contains($0.id) }.map(\.tsv))
        .onDeleteCommand { model.deleteSelected() }
        .overlay {
            if model.isLoading && model.rows.isEmpty { ProgressView() }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .textSelection(.enabled)
                Button("Dismiss") { model.errorMessage = nil }.buttonStyle(.link)
            } else if !model.isEditable {
                Label("Read-only: no primary key", systemImage: "lock")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !model.changes.isEmpty {
                Text("\(model.changes.count) pending change\(model.changes.count == 1 ? "" : "s")")
                    .foregroundStyle(.orange)
            }
            Text(model.rangeDescription).monospacedDigit().foregroundStyle(.secondary)
            Button("Count") { Task { await model.countRows() } }
                .buttonStyle(.link)
                .help("Run an exact count(*)")
            ControlGroup {
                Button("Previous Page", systemImage: "chevron.left") { Task { await model.goToPage(model.page - 1) } }
                    .disabled(!model.hasPreviousPage)
                Button("Next Page", systemImage: "chevron.right") { Task { await model.goToPage(model.page + 1) } }
                    .disabled(!model.hasNextPage)
            }
            .fixedSize()
        }
        .font(.callout)
        .padding(.horizontal)
        .padding(.vertical, 6)
    }

    private func copy(_ ids: Set<Int>) {
        let text = model.gridRows.filter { ids.contains($0.id) }.map(\.tsv).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

nonisolated struct IndexedColumn: Identifiable, Sendable {
    let index: Int
    let column: ColumnInfo
    var id: Int { index }
}

private struct GridCell: View {
    let row: GridRow
    let column: Int

    var body: some View {
        CellText(value: row[column])
            .strikethrough(row.state == .deleted)
            .foregroundStyle(row.state == .deleted ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
            .padding(.horizontal, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background, in: .rect(cornerRadius: 3))
    }

    private var background: Color {
        switch row.state {
        case .inserted: .green.opacity(0.18)
        case .deleted: .red.opacity(0.12)
        case .normal: row.modifiedColumns.contains(column) ? .orange.opacity(0.25) : .clear
        }
    }
}

extension GridRow {
    var tsv: String { values.map { $0.isNull ? "" : $0.displayString }.joined(separator: "\t") }
}

/// Toolbar items for the active data grid.
struct TableDataToolbar: ToolbarContent {
    @Bindable var data: TableDataModel

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button("Add Row", systemImage: "plus") { data.addRow() }
                .disabled(!data.isEditable)
                .help("Add Row (⌥⌘N)")
            Button("Delete Row", systemImage: "minus") { data.deleteSelected() }
                .disabled(!data.isEditable || data.selection.isEmpty)
                .help("Delete Selected Rows (⌘⌫)")
        }
        ToolbarSpacer(.fixed)
        ToolbarItemGroup(placement: .primaryAction) {
            Button("Discard", systemImage: "arrow.uturn.backward") { data.discard() }
                .disabled(data.changes.isEmpty)
                .help("Discard all pending changes")
            Button {
                Task { await data.save() }
            } label: {
                Label(data.changes.isEmpty ? "Save" : "Save (\(data.changes.count))", systemImage: "checkmark")
            }
            .buttonStyle(.glassProminent)
            .disabled(data.changes.isEmpty || data.isSaving)
            .badge(data.changes.count)
            .help("Save changes in one transaction (⌘S)")
        }
        ToolbarSpacer(.fixed)
        ToolbarItem(placement: .primaryAction) {
            ExportMenu(resultSet: { data.exportableResult }, filename: data.structure.relation.name)
        }
    }
}

extension TableDataModel {
    /// Current page as a `ResultSet`, with pending edits applied.
    var exportableResult: ResultSet {
        ResultSet(
            columns: columns.enumerated().map { ResultColumn(index: $0.offset, name: $0.element.name, typeOID: 0) },
            rows: gridRows.filter { $0.state != .deleted }.enumerated().map { ResultRow(id: $0.offset, values: $0.element.values) })
    }
}
