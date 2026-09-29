/// A database on the server.
public struct DatabaseInfo: Sendable, Hashable, Identifiable {
    public var name: String
    public var id: String { name }
    public init(name: String) { self.name = name }
}

/// A schema (namespace).
public struct SchemaInfo: Sendable, Hashable, Identifiable {
    public var name: String
    public var isSystem: Bool
    public var id: String { name }
    public init(name: String, isSystem: Bool) {
        self.name = name
        self.isSystem = isSystem
    }
}

/// Kind of relation, from `pg_class.relkind`.
public enum RelationKind: String, Sendable, Hashable, Codable, CaseIterable {
    case table = "r"
    case partitionedTable = "p"
    case view = "v"
    case materializedView = "m"
    case foreignTable = "f"

    public var label: String {
        switch self {
        case .table: "Table"
        case .partitionedTable: "Partitioned Table"
        case .view: "View"
        case .materializedView: "Materialized View"
        case .foreignTable: "Foreign Table"
        }
    }

    public var systemImage: String {
        switch self {
        case .table, .partitionedTable: "tablecells"
        case .view: "eye"
        case .materializedView: "square.stack.3d.up"
        case .foreignTable: "globe"
        }
    }

    /// Whether rows can be located by `ctid` (plain tables only).
    public var supportsCTID: Bool { self == .table || self == .materializedView }
}

/// A table, view, materialized view or foreign table.
public struct RelationInfo: Sendable, Hashable, Identifiable, Codable {
    public var oid: UInt32
    public var schema: String
    public var name: String
    public var kind: RelationKind
    /// Planner estimate from `pg_class.reltuples`; `nil` when never analyzed.
    public var estimatedRows: Int?

    public var id: UInt32 { oid }
    public var qualifiedName: String { SQLIdentifier.qualified(schema: schema, name: name) }

    public init(oid: UInt32, schema: String, name: String, kind: RelationKind, estimatedRows: Int?) {
        self.oid = oid
        self.schema = schema
        self.name = name
        self.kind = kind
        self.estimatedRows = estimatedRows
    }
}

/// A column of a relation.
public struct ColumnInfo: Sendable, Hashable, Identifiable {
    /// `pg_attribute.attnum`.
    public var position: Int
    public var name: String
    /// Output of `format_type(atttypid, atttypmod)`, usable in casts.
    public var dataType: String
    public var notNull: Bool
    public var defaultExpression: String?
    public var isIdentity: Bool
    public var isGenerated: Bool
    /// 1-based position within the primary key, if part of it.
    public var primaryKeyOrdinal: Int?

    public var id: Int { position }
    public var isPrimaryKey: Bool { primaryKeyOrdinal != nil }
    /// Generated columns can never be written.
    public var isWritable: Bool { !isGenerated }

    public init(
        position: Int, name: String, dataType: String, notNull: Bool, defaultExpression: String? = nil,
        isIdentity: Bool = false, isGenerated: Bool = false, primaryKeyOrdinal: Int? = nil
    ) {
        self.position = position
        self.name = name
        self.dataType = dataType
        self.notNull = notNull
        self.defaultExpression = defaultExpression
        self.isIdentity = isIdentity
        self.isGenerated = isGenerated
        self.primaryKeyOrdinal = primaryKeyOrdinal
    }
}

public struct IndexInfo: Sendable, Hashable, Identifiable {
    public var name: String
    public var definition: String
    public var isPrimary: Bool
    public var isUnique: Bool
    public var id: String { name }
    public init(name: String, definition: String, isPrimary: Bool, isUnique: Bool) {
        self.name = name
        self.definition = definition
        self.isPrimary = isPrimary
        self.isUnique = isUnique
    }
}

public struct ConstraintInfo: Sendable, Hashable, Identifiable {
    public var name: String
    /// `pg_constraint.contype`: p, u, f, c, x, t, n.
    public var type: String
    public var definition: String
    public var id: String { name }

    public var typeLabel: String {
        switch type {
        case "p": "Primary Key"
        case "u": "Unique"
        case "f": "Foreign Key"
        case "c": "Check"
        case "x": "Exclusion"
        case "t": "Trigger"
        case "n": "Not Null"
        default: type
        }
    }

    public init(name: String, type: String, definition: String) {
        self.name = name
        self.type = type
        self.definition = definition
    }
}

/// Full description of a relation used by the structure tab and the data grid.
public struct TableStructure: Sendable, Hashable {
    public var relation: RelationInfo
    public var columns: [ColumnInfo]
    public var indexes: [IndexInfo]
    public var constraints: [ConstraintInfo]

    public init(relation: RelationInfo, columns: [ColumnInfo], indexes: [IndexInfo] = [], constraints: [ConstraintInfo] = []) {
        self.relation = relation
        self.columns = columns
        self.indexes = indexes
        self.constraints = constraints
    }

    public var primaryKey: [ColumnInfo] {
        columns.filter(\.isPrimaryKey).sorted { $0.primaryKeyOrdinal! < $1.primaryKeyOrdinal! }
    }

    /// How rows of this relation can be identified for editing.
    public var rowIdentity: RowIdentity {
        if relation.kind == .view || relation.kind == .materializedView { return .readOnly }
        let pk = primaryKey
        if !pk.isEmpty { return .primaryKey(pk.map(\.name)) }
        if relation.kind == .table { return .ctid }
        return .readOnly
    }
}

/// Strategy used to locate an existing row when editing.
public enum RowIdentity: Sendable, Hashable {
    case primaryKey([String])
    case ctid
    case readOnly

    public var isEditable: Bool { self != .readOnly }
}
