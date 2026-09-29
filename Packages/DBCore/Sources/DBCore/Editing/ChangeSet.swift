/// A row loaded from a table, with its identity for later edits.
public struct TableRow: Sendable, Hashable, Identifiable {
    /// Stable id within the loaded page.
    public var id: Int
    /// `ctid` of the row when the relation has no primary key.
    public var ctid: String?
    /// Original values, one per column of the structure.
    public var values: [CellValue]

    public init(id: Int, ctid: String? = nil, values: [CellValue]) {
        self.id = id
        self.ctid = ctid
        self.values = values
    }
}

/// A row being inserted.
public struct NewRow: Sendable, Hashable, Identifiable {
    public var id: Int
    public var values: [CellValue]
    public init(id: Int, values: [CellValue]) {
        self.id = id
        self.values = values
    }
}

/// Pending modifications to a table. Pure value type; UI wraps it in an observable model.
public struct ChangeSet: Sendable, Hashable {
    /// Row id → (column index → new value).
    public var updates: [Int: [Int: CellValue]] = [:]
    public var inserts: [NewRow] = []
    public var deletes: Set<Int> = []

    public init() {}

    public var isEmpty: Bool { updates.isEmpty && inserts.isEmpty && deletes.isEmpty }

    public var count: Int {
        updates.values.reduce(0) { $0 + $1.count } + inserts.count + deletes.count
    }

    /// Records a new value for an existing row, dropping it if it equals the original.
    public mutating func set(_ value: CellValue, row: TableRow, column: Int) {
        if row.values[safe: column] == value {
            updates[row.id]?[column] = nil
            if updates[row.id]?.isEmpty == true { updates[row.id] = nil }
        } else {
            updates[row.id, default: [:]][column] = value
        }
    }

    public func value(row: TableRow, column: Int) -> CellValue {
        updates[row.id]?[column] ?? row.values[safe: column] ?? .null
    }

    public func isModified(row: Int, column: Int) -> Bool {
        updates[row]?[column] != nil
    }
}

public enum ChangeSetError: Error, Sendable, Equatable, CustomStringConvertible {
    case readOnly
    case missingRow(Int)
    case missingIdentity(row: Int)

    public var description: String {
        switch self {
        case .readOnly: "This relation is read-only: it is a view or has no way to identify rows."
        case .missingRow(let id): "Row \(id) is no longer loaded."
        case .missingIdentity(let id): "Row \(id) has no identity (primary key value or ctid)."
        }
    }
}

/// Generates DML from a `ChangeSet`. All values are bound as text and cast with the column type,
/// so every type works through its I/O conversion.
public enum ChangeSetSQL {
    public static func statements(
        for changes: ChangeSet, structure: TableStructure, rows: [TableRow]
    ) throws(ChangeSetError) -> [BoundStatement] {
        let identity = structure.rowIdentity
        let table = structure.relation.qualifiedName
        let columns = structure.columns
        let byID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var result: [BoundStatement] = []

        if !changes.isEmpty, !identity.isEditable { throw .readOnly }

        // Deletes first so a delete + insert of the same key works.
        for rowID in changes.deletes.sorted() {
            guard let row = byID[rowID] else { throw .missingRow(rowID) }
            var binds: [String?] = []
            let condition = try whereClause(identity: identity, columns: columns, row: row, binds: &binds)
            result.append(BoundStatement(sql: "DELETE FROM \(table) WHERE \(condition)", binds: binds))
        }

        for rowID in changes.updates.keys.sorted() where !changes.deletes.contains(rowID) {
            guard let row = byID[rowID] else { throw .missingRow(rowID) }
            let changed = changes.updates[rowID]!.sorted { $0.key < $1.key }
            if changed.isEmpty { continue }
            var binds: [String?] = []
            var sets: [String] = []
            for (index, value) in changed {
                let column = columns[index]
                if value == .default {
                    sets.append("\(SQLIdentifier.quote(column.name)) = DEFAULT")
                } else {
                    binds.append(value.text)
                    sets.append("\(SQLIdentifier.quote(column.name)) = $\(binds.count)::\(column.dataType)")
                }
            }
            let condition = try whereClause(identity: identity, columns: columns, row: row, binds: &binds)
            result.append(BoundStatement(
                sql: "UPDATE \(table) SET \(sets.joined(separator: ", ")) WHERE \(condition)", binds: binds))
        }

        for row in changes.inserts {
            var names: [String] = []
            var values: [String] = []
            var binds: [String?] = []
            for (index, column) in columns.enumerated() {
                let value = row.values[safe: index] ?? .default
                if value == .default || !column.isWritable { continue }
                binds.append(value.text)
                names.append(SQLIdentifier.quote(column.name))
                values.append("$\(binds.count)::\(column.dataType)")
            }
            let sql = names.isEmpty
                ? "INSERT INTO \(table) DEFAULT VALUES"
                : "INSERT INTO \(table) (\(names.joined(separator: ", "))) VALUES (\(values.joined(separator: ", ")))"
            result.append(BoundStatement(sql: sql, binds: binds))
        }
        return result
    }

    private static func whereClause(
        identity: RowIdentity, columns: [ColumnInfo], row: TableRow, binds: inout [String?]
    ) throws(ChangeSetError) -> String {
        switch identity {
        case .readOnly:
            throw .readOnly
        case .ctid:
            guard let ctid = row.ctid else { throw .missingIdentity(row: row.id) }
            binds.append(ctid)
            return "ctid = $\(binds.count)::tid"
        case .primaryKey(let keys):
            var parts: [String] = []
            for key in keys {
                guard let index = columns.firstIndex(where: { $0.name == key }),
                      let value = row.values[safe: index]?.text else { throw .missingIdentity(row: row.id) }
                binds.append(value)
                parts.append("\(SQLIdentifier.quote(key)) = $\(binds.count)::\(columns[index].dataType)")
            }
            return parts.joined(separator: " AND ")
        }
    }
}
