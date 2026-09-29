/// Catalog queries (`pg_catalog`, not `information_schema`, for speed).
/// Every output column is cast to text so results decode uniformly.
public enum CatalogQueries {
    public static let databases = """
        SELECT datname::text FROM pg_database
        WHERE datallowconn AND NOT datistemplate
        ORDER BY datname
        """

    public static let schemas = """
        SELECT nspname::text,
               (nspname LIKE 'pg\\_%' OR nspname = 'information_schema')::text AS is_system
        FROM pg_namespace
        ORDER BY (nspname LIKE 'pg\\_%' OR nspname = 'information_schema'), nspname
        """

    /// `$1` = schema name.
    public static let relations = """
        SELECT c.oid::text, n.nspname::text, c.relname::text, c.relkind::text,
               CASE WHEN c.reltuples < 0 THEN NULL ELSE c.reltuples::bigint END::text
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = $1 AND c.relkind IN ('r','p','v','m','f') AND NOT c.relispartition
        ORDER BY c.relname
        """

    /// `$1` = relation OID.
    public static let columns = """
        SELECT a.attnum::text, a.attname::text, format_type(a.atttypid, a.atttypmod)::text,
               a.attnotnull::text, pg_get_expr(d.adbin, d.adrelid)::text,
               (a.attidentity <> '')::text, (a.attgenerated <> '')::text,
               (SELECT k.ord FROM pg_index i, unnest(i.indkey) WITH ORDINALITY AS k(attnum, ord)
                WHERE i.indrelid = a.attrelid AND i.indisprimary AND k.attnum = a.attnum)::text
        FROM pg_attribute a
        LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
        WHERE a.attrelid = $1::oid AND a.attnum > 0 AND NOT a.attisdropped
        ORDER BY a.attnum
        """

    /// `$1` = relation OID.
    public static let indexes = """
        SELECT ic.relname::text, pg_get_indexdef(i.indexrelid)::text, i.indisprimary::text, i.indisunique::text
        FROM pg_index i
        JOIN pg_class ic ON ic.oid = i.indexrelid
        WHERE i.indrelid = $1::oid
        ORDER BY i.indisprimary DESC, ic.relname
        """

    /// `$1` = relation OID.
    public static let constraints = """
        SELECT conname::text, contype::text, pg_get_constraintdef(oid, true)::text
        FROM pg_constraint
        WHERE conrelid = $1::oid
        ORDER BY contype, conname
        """

    /// `$1` = relation OID.
    public static let relation = """
        SELECT c.oid::text, n.nspname::text, c.relname::text, c.relkind::text,
               CASE WHEN c.reltuples < 0 THEN NULL ELSE c.reltuples::bigint END::text
        FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE c.oid = $1::oid
        """

    // MARK: Row parsing

    public static func parseDatabases(_ rows: [[CellValue]]) -> [DatabaseInfo] {
        rows.compactMap { $0.first?.text.map(DatabaseInfo.init) }
    }

    public static func parseSchemas(_ rows: [[CellValue]]) -> [SchemaInfo] {
        rows.compactMap { r in
            guard let name = r[safe: 0]?.text else { return nil }
            return SchemaInfo(name: name, isSystem: r[safe: 1]?.text == "true")
        }
    }

    public static func parseRelations(_ rows: [[CellValue]]) -> [RelationInfo] {
        rows.compactMap { r in
            guard let oid = r[safe: 0]?.text.flatMap(UInt32.init),
                  let schema = r[safe: 1]?.text, let name = r[safe: 2]?.text,
                  let kind = r[safe: 3]?.text.flatMap(RelationKind.init(rawValue:)) else { return nil }
            return RelationInfo(oid: oid, schema: schema, name: name, kind: kind,
                                estimatedRows: r[safe: 4]?.text.flatMap(Int.init))
        }
    }

    public static func parseColumns(_ rows: [[CellValue]]) -> [ColumnInfo] {
        rows.compactMap { r in
            guard let pos = r[safe: 0]?.text.flatMap(Int.init), let name = r[safe: 1]?.text,
                  let type = r[safe: 2]?.text else { return nil }
            return ColumnInfo(
                position: pos, name: name, dataType: type,
                notNull: r[safe: 3]?.text == "true",
                defaultExpression: r[safe: 4]?.text,
                isIdentity: r[safe: 5]?.text == "true",
                isGenerated: r[safe: 6]?.text == "true",
                primaryKeyOrdinal: r[safe: 7]?.text.flatMap(Int.init)
            )
        }
    }

    public static func parseIndexes(_ rows: [[CellValue]]) -> [IndexInfo] {
        rows.compactMap { r in
            guard let name = r[safe: 0]?.text, let def = r[safe: 1]?.text else { return nil }
            return IndexInfo(name: name, definition: def, isPrimary: r[safe: 2]?.text == "true",
                             isUnique: r[safe: 3]?.text == "true")
        }
    }

    public static func parseConstraints(_ rows: [[CellValue]]) -> [ConstraintInfo] {
        rows.compactMap { r in
            guard let name = r[safe: 0]?.text, let type = r[safe: 1]?.text, let def = r[safe: 2]?.text else { return nil }
            return ConstraintInfo(name: name, type: type, definition: def)
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
