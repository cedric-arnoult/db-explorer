import Foundation

/// Sort order for the data grid.
public struct SortDescriptor: Sendable, Hashable {
    public var column: String
    public var ascending: Bool
    public init(column: String, ascending: Bool = true) {
        self.column = column
        self.ascending = ascending
    }
}

/// A SQL statement with text parameters (`nil` = NULL).
public struct BoundStatement: Sendable, Hashable {
    public var sql: String
    public var binds: [String?]
    public init(sql: String, binds: [String?] = []) {
        self.sql = sql
        self.binds = binds
    }
}

/// Builds the queries used by the table browser.
///
/// Every column is selected as `::text`, so values decode as strings and round-trip exactly when edited.
public struct TableQuery: Sendable, Hashable {
    public static let ctidColumn = "__dbexplorer_ctid"
    public static let defaultPageSize = 500

    public var structure: TableStructure
    public var filter: String
    public var sort: SortDescriptor?
    public var pageSize: Int
    public var page: Int

    public init(structure: TableStructure, filter: String = "", sort: SortDescriptor? = nil,
                pageSize: Int = TableQuery.defaultPageSize, page: Int = 0) {
        self.structure = structure
        self.filter = filter
        self.sort = sort
        self.pageSize = pageSize
        self.page = page
    }

    /// Whether the first selected column is the row's `ctid`.
    public var includesCTID: Bool { structure.rowIdentity == .ctid }

    private var whereClause: String {
        let f = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        return f.isEmpty ? "" : " WHERE \(f)"
    }

    public var selectSQL: String {
        var cols: [String] = []
        if includesCTID { cols.append("ctid::text AS \(SQLIdentifier.quote(Self.ctidColumn))") }
        for (i, c) in structure.columns.enumerated() {
            // Alias positionally so ORDER BY on a real column name sorts by the original type, not text.
            cols.append("\(SQLIdentifier.quote(c.name))::text AS \"c\(i)\"")
        }
        if cols.isEmpty { cols.append("NULL") }
        var sql = "SELECT \(cols.joined(separator: ", ")) FROM \(structure.relation.qualifiedName)\(whereClause)"
        let order: [String]
        if let sort {
            order = ["\(SQLIdentifier.quote(sort.column)) \(sort.ascending ? "ASC" : "DESC")"]
        } else {
            order = structure.primaryKey.map { SQLIdentifier.quote($0.name) }
        }
        if !order.isEmpty { sql += " ORDER BY \(order.joined(separator: ", "))" }
        sql += " LIMIT \(pageSize) OFFSET \(page * pageSize)"
        return sql
    }

    public var countSQL: String {
        "SELECT count(*)::text FROM \(structure.relation.qualifiedName)\(whereClause)"
    }
}
