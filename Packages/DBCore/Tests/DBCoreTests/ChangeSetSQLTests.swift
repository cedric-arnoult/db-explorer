import Testing
@testable import DBCore

@Suite struct ChangeSetSQLTests {
    let users = TableStructure(
        relation: RelationInfo(oid: 1, schema: "public", name: "users", kind: .table, estimatedRows: 10),
        columns: [
            ColumnInfo(position: 1, name: "id", dataType: "integer", notNull: true, defaultExpression: "nextval('s')", primaryKeyOrdinal: 1),
            ColumnInfo(position: 2, name: "name", dataType: "character varying(50)", notNull: false),
            ColumnInfo(position: 3, name: "meta", dataType: "jsonb", notNull: false),
            ColumnInfo(position: 4, name: "full", dataType: "text", notNull: false, isGenerated: true),
        ])

    var rows: [TableRow] {
        [TableRow(id: 0, values: [.text("1"), .text("Ann"), .null, .text("x")]),
         TableRow(id: 1, values: [.text("2"), .text("Bob"), .text("{}"), .text("y")])]
    }

    @Test func update() throws {
        var changes = ChangeSet()
        changes.set(.null, row: rows[0], column: 1)
        changes.set(.text("{}"), row: rows[0], column: 2)
        let sql = try ChangeSetSQL.statements(for: changes, structure: users, rows: rows)
        #expect(sql == [BoundStatement(
            sql: "UPDATE \"public\".\"users\" SET \"name\" = $1::character varying(50), \"meta\" = $2::jsonb WHERE \"id\" = $3::integer",
            binds: [nil, "{}", "1"])])
    }

    @Test func settingOriginalValueRemovesChange() {
        var changes = ChangeSet()
        changes.set(.text("Anna"), row: rows[0], column: 1)
        changes.set(.text("Ann"), row: rows[0], column: 1)
        #expect(changes.isEmpty)
    }

    @Test func insertOmitsDefaultsAndGenerated() throws {
        var changes = ChangeSet()
        changes.inserts = [NewRow(id: -1, values: [.default, .text("Cy"), .null, .text("ignored")])]
        let sql = try ChangeSetSQL.statements(for: changes, structure: users, rows: rows)
        #expect(sql == [BoundStatement(
            sql: "INSERT INTO \"public\".\"users\" (\"name\", \"meta\") VALUES ($1::character varying(50), $2::jsonb)",
            binds: ["Cy", nil])])
    }

    @Test func insertAllDefaults() throws {
        var changes = ChangeSet()
        changes.inserts = [NewRow(id: -1, values: [.default, .default, .default, .default])]
        let sql = try ChangeSetSQL.statements(for: changes, structure: users, rows: rows)
        #expect(sql.map(\.sql) == ["INSERT INTO \"public\".\"users\" DEFAULT VALUES"])
    }

    @Test func deleteComesFirstAndSkipsUpdates() throws {
        var changes = ChangeSet()
        changes.set(.text("B"), row: rows[1], column: 1)
        changes.deletes = [1]
        changes.inserts = [NewRow(id: -1, values: [.text("2"), .text("New"), .default, .default])]
        let sql = try ChangeSetSQL.statements(for: changes, structure: users, rows: rows)
        #expect(sql.map(\.sql) == [
            "DELETE FROM \"public\".\"users\" WHERE \"id\" = $1::integer",
            "INSERT INTO \"public\".\"users\" (\"id\", \"name\") VALUES ($1::integer, $2::character varying(50))",
        ])
        #expect(sql[0].binds == ["2"])
    }

    @Test func compositeKey() throws {
        var s = users
        s.columns[1].primaryKeyOrdinal = 2
        var changes = ChangeSet()
        changes.deletes = [0]
        let sql = try ChangeSetSQL.statements(for: changes, structure: s, rows: rows)
        #expect(sql.first?.sql == "DELETE FROM \"public\".\"users\" WHERE \"id\" = $1::integer AND \"name\" = $2::character varying(50)")
        #expect(sql.first?.binds == ["1", "Ann"])
    }

    @Test func ctidIdentity() throws {
        var s = users
        s.columns[0].primaryKeyOrdinal = nil
        #expect(s.rowIdentity == .ctid)
        let row = TableRow(id: 5, ctid: "(0,3)", values: [.text("1"), .text("Ann"), .null, .null])
        var changes = ChangeSet()
        changes.set(.text("Z"), row: row, column: 1)
        let sql = try ChangeSetSQL.statements(for: changes, structure: s, rows: [row])
        #expect(sql.first?.sql == "UPDATE \"public\".\"users\" SET \"name\" = $1::character varying(50) WHERE ctid = $2::tid")
        #expect(sql.first?.binds == ["Z", "(0,3)"])
    }

    @Test func updateToDefault() throws {
        var changes = ChangeSet()
        changes.set(.default, row: rows[0], column: 1)
        let sql = try ChangeSetSQL.statements(for: changes, structure: users, rows: rows)
        #expect(sql.first?.sql == "UPDATE \"public\".\"users\" SET \"name\" = DEFAULT WHERE \"id\" = $1::integer")
    }

    @Test func viewsAreReadOnly() {
        var s = users
        s.relation.kind = .view
        #expect(s.rowIdentity == .readOnly)
        var changes = ChangeSet()
        changes.deletes = [0]
        #expect(throws: ChangeSetError.readOnly) { try ChangeSetSQL.statements(for: changes, structure: s, rows: rows) }
    }

    @Test func missingRow() {
        var changes = ChangeSet()
        changes.deletes = [42]
        #expect(throws: ChangeSetError.missingRow(42)) { try ChangeSetSQL.statements(for: changes, structure: users, rows: rows) }
    }
}

@Suite struct TableQueryTests {
    let structure = TableStructure(
        relation: RelationInfo(oid: 1, schema: "s", name: "t", kind: .table, estimatedRows: nil),
        columns: [ColumnInfo(position: 1, name: "id", dataType: "bigint", notNull: true, primaryKeyOrdinal: 1),
                  ColumnInfo(position: 2, name: "v", dataType: "text", notNull: false)])

    @Test func defaultOrderByPrimaryKey() {
        let q = TableQuery(structure: structure)
        #expect(q.selectSQL == "SELECT \"id\"::text AS \"c0\", \"v\"::text AS \"c1\" FROM \"s\".\"t\" ORDER BY \"id\" LIMIT 500 OFFSET 0")
    }

    @Test func filterSortAndPage() {
        let q = TableQuery(structure: structure, filter: " v like 'a%' ", sort: .init(column: "v", ascending: false), pageSize: 50, page: 2)
        #expect(q.selectSQL == "SELECT \"id\"::text AS \"c0\", \"v\"::text AS \"c1\" FROM \"s\".\"t\" WHERE v like 'a%' ORDER BY \"v\" DESC LIMIT 50 OFFSET 100")
        #expect(q.countSQL == "SELECT count(*)::text FROM \"s\".\"t\" WHERE v like 'a%'")
    }

    @Test func ctidSelectedWithoutPrimaryKey() {
        var s = structure
        s.columns[0].primaryKeyOrdinal = nil
        let q = TableQuery(structure: s)
        #expect(q.includesCTID)
        #expect(q.selectSQL.hasPrefix("SELECT ctid::text AS \"__dbexplorer_ctid\", "))
        #expect(!q.selectSQL.contains("ORDER BY"))
    }
}

@Suite struct ResultExporterTests {
    let result = ResultSet(
        columns: [ResultColumn(index: 0, name: "id", typeOID: 23), ResultColumn(index: 1, name: "note", typeOID: 25)],
        rows: [ResultRow(id: 0, values: [.text("1"), .text("a,\"b\"\nc")]), ResultRow(id: 1, values: [.text("2"), .null])])

    @Test func csv() {
        #expect(ResultExporter.csv(result) == "id,note\r\n1,\"a,\"\"b\"\"\nc\"\r\n2,\r\n")
    }

    @Test func json() {
        #expect(ResultExporter.json(result) == "[\n  {\"id\": \"1\", \"note\": \"a,\\\"b\\\"\\nc\"},\n  {\"id\": \"2\", \"note\": null}\n]\n")
        #expect(ResultExporter.json(.empty) == "[]\n")
    }
}

@Suite struct CatalogParsingTests {
    @Test func columns() {
        let rows: [[CellValue]] = [[.text("1"), .text("id"), .text("integer"), .text("true"), .text("nextval('x')"), .text("false"), .text("false"), .text("1")],
                                   [.text("2"), .text("n"), .text("text"), .text("false"), .null, .text("false"), .text("true"), .null]]
        let cols = CatalogQueries.parseColumns(rows)
        #expect(cols.count == 2)
        #expect(cols[0].isPrimaryKey && cols[0].notNull && cols[0].defaultExpression == "nextval('x')")
        #expect(!cols[1].isPrimaryKey && cols[1].isGenerated && !cols[1].isWritable)
    }

    @Test func relations() {
        let rels = CatalogQueries.parseRelations([[.text("42"), .text("public"), .text("v"), .text("v"), .null]])
        #expect(rels == [RelationInfo(oid: 42, schema: "public", name: "v", kind: .view, estimatedRows: nil)])
    }
}
