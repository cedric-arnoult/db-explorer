import Foundation
import DBCore

/// A row as displayed in the grid: original values with pending edits applied.
nonisolated struct GridRow: Identifiable, Hashable, Sendable {
    enum State: Hashable, Sendable {
        case normal, inserted, deleted
    }
    let id: Int
    let values: [CellValue]
    let state: State
    let modifiedColumns: Set<Int>

    subscript(column: Int) -> CellValue {
        column < values.count ? values[column] : .null
    }
}

/// Paged table contents plus pending changes (update / insert / delete), with undo.
@Observable
final class TableDataModel {
    var structure: TableStructure
    let session: DatabaseSession
    weak var owner: DatabaseModel?

    private(set) var rows: [TableRow] = []
    private(set) var changes = ChangeSet()
    var selection: Set<Int> = []

    var filterDraft = ""
    private(set) var appliedFilter = ""
    var sort: DBCore.SortDescriptor?
    private(set) var page = 0
    let pageSize = TableQuery.defaultPageSize
    private(set) var exactCount: Int?
    private(set) var isLoading = false
    private(set) var isSaving = false
    var errorMessage: String?
    private var nextNewRowID = -1

    init(structure: TableStructure, session: DatabaseSession, owner: DatabaseModel?) {
        self.structure = structure
        self.session = session
        self.owner = owner
    }

    var isEditable: Bool { structure.rowIdentity.isEditable }
    var columns: [ColumnInfo] { structure.columns }

    var query: TableQuery {
        TableQuery(structure: structure, filter: appliedFilter, sort: sort, pageSize: pageSize, page: page)
    }

    var gridRows: [GridRow] {
        var result = rows.map { row in
            let modified = changes.updates[row.id] ?? [:]
            var values = row.values
            for (column, value) in modified where column < values.count { values[column] = value }
            return GridRow(
                id: row.id, values: values,
                state: changes.deletes.contains(row.id) ? .deleted : .normal,
                modifiedColumns: Set(modified.keys))
        }
        result += changes.inserts.map { GridRow(id: $0.id, values: $0.values, state: .inserted, modifiedColumns: []) }
        return result
    }

    func gridRow(id: Int) -> GridRow? {
        gridRows.first { $0.id == id }
    }

    // MARK: Loading

    func reload() async {
        isLoading = true
        defer { isLoading = false }
        do {
            rows = try await session.fetchPage(query)
            errorMessage = nil
            selection = selection.filter { id in rows.contains { $0.id == id } || changes.inserts.contains { $0.id == id } }
        } catch {
            errorMessage = error.fullDescription
        }
    }

    func applyFilter() async {
        appliedFilter = filterDraft
        page = 0
        exactCount = nil
        await reload()
    }

    func setSort(_ descriptor: DBCore.SortDescriptor?) async {
        guard descriptor != sort else { return }
        sort = descriptor
        page = 0
        await reload()
    }

    var hasNextPage: Bool {
        if let exactCount { return (page + 1) * pageSize < exactCount }
        return rows.count == pageSize
    }

    var hasPreviousPage: Bool { page > 0 }

    func goToPage(_ newPage: Int) async {
        guard newPage >= 0, newPage != page else { return }
        page = newPage
        await reload()
    }

    func countRows() async {
        do {
            exactCount = try await session.exactCount(query)
        } catch {
            errorMessage = error.fullDescription
        }
    }

    /// "Rows 1–500 of ~12,340"
    var rangeDescription: String {
        let first = rows.isEmpty ? 0 : page * pageSize + 1
        let last = page * pageSize + rows.count
        let total: String
        if let exactCount {
            total = exactCount.formatted()
        } else if appliedFilter.isEmpty, let estimate = structure.relation.estimatedRows {
            total = "~" + estimate.formatted()
        } else {
            total = "?"
        }
        return "\(first.formatted())–\(last.formatted()) of \(total)"
    }

    // MARK: Editing (every mutation is undoable)

    func value(rowID: Int, column: Int) -> CellValue {
        gridRow(id: rowID)?[column] ?? .null
    }

    func setValue(_ value: CellValue, rowID: Int, column: Int) {
        mutate("Edit Cell") { changes in
            if let index = changes.inserts.firstIndex(where: { $0.id == rowID }) {
                changes.inserts[index].values[column] = value
            } else if let row = rows.first(where: { $0.id == rowID }) {
                changes.set(value, row: row, column: column)
            }
        }
    }

    @discardableResult
    func addRow() -> Int? {
        guard isEditable else { return nil }
        let id = nextNewRowID
        nextNewRowID -= 1
        let values: [CellValue] = columns.map { column in
            column.defaultExpression != nil || column.isIdentity || column.isGenerated || !column.notNull ? .default : .text("")
        }
        mutate("Add Row") { $0.inserts.append(NewRow(id: id, values: values)) }
        selection = [id]
        return id
    }

    func deleteSelected() {
        guard isEditable, !selection.isEmpty else { return }
        let ids = selection
        mutate(ids.count == 1 ? "Delete Row" : "Delete Rows") { changes in
            changes.inserts.removeAll { ids.contains($0.id) }
            for id in ids where id >= 0 { changes.deletes.insert(id) }
        }
    }

    func restoreSelected() {
        let ids = selection
        mutate("Restore Rows") { changes in
            for id in ids { changes.deletes.remove(id) }
        }
    }

    func discard() {
        guard !changes.isEmpty else { return }
        mutate("Discard Changes") { $0 = ChangeSet() }
    }

    func save() async {
        guard !changes.isEmpty, !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            let statements = try ChangeSetSQL.statements(for: changes, structure: structure, rows: rows)
            try await session.apply(statements)
            changes = ChangeSet()
            owner?.undoManager?.removeAllActions(withTarget: self)
            errorMessage = nil
            exactCount = nil
            await reload()
        } catch let error as ChangeSetError {
            errorMessage = error.description
        } catch let error as DatabaseError {
            errorMessage = error.fullDescription
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func mutate(_ actionName: String, _ body: (inout ChangeSet) -> Void) {
        let previous = changes
        body(&changes)
        guard changes != previous else { return }
        registerUndo(restoring: previous, actionName: actionName)
    }

    private func restore(_ snapshot: ChangeSet, actionName: String) {
        let current = changes
        changes = snapshot
        registerUndo(restoring: current, actionName: actionName)
    }

    private func registerUndo(restoring snapshot: ChangeSet, actionName: String) {
        guard let undoManager = owner?.undoManager else { return }
        undoManager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.restore(snapshot, actionName: actionName) }
        }
        undoManager.setActionName(actionName)
    }
}
