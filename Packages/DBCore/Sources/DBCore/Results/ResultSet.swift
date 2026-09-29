/// Column metadata of a result set.
public struct ResultColumn: Sendable, Hashable, Identifiable {
    public var index: Int
    public var name: String
    /// Postgres type OID.
    public var typeOID: UInt32
    public var id: Int { index }

    public init(index: Int, name: String, typeOID: UInt32) {
        self.index = index
        self.name = name
        self.typeOID = typeOID
    }
}

/// A row of a result set, identifiable by its position.
public struct ResultRow: Sendable, Hashable, Identifiable {
    public var id: Int
    public var values: [CellValue]

    public init(id: Int, values: [CellValue]) {
        self.id = id
        self.values = values
    }

    public subscript(column: Int) -> CellValue {
        column < values.count ? values[column] : .null
    }
}

/// A fully materialised result.
public struct ResultSet: Sendable, Hashable {
    public var columns: [ResultColumn]
    public var rows: [ResultRow]

    public init(columns: [ResultColumn] = [], rows: [ResultRow] = []) {
        self.columns = columns
        self.rows = rows
    }

    public static let empty = ResultSet()
}

/// Outcome of executing one statement.
public struct StatementResult: Sendable {
    /// Command tag, e.g. `SELECT`, `UPDATE`, `CREATE TABLE`.
    public var command: String
    /// Rows affected / returned, when reported by the server.
    public var rowCount: Int?
    public var resultSet: ResultSet
    public var duration: Duration
    /// Whether rows beyond the display limit were dropped.
    public var isTruncated: Bool

    public init(command: String, rowCount: Int?, resultSet: ResultSet, duration: Duration, isTruncated: Bool = false) {
        self.command = command
        self.rowCount = rowCount
        self.resultSet = resultSet
        self.duration = duration
        self.isTruncated = isTruncated
    }
}
