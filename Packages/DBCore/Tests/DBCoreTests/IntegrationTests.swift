import Foundation
import Testing
@testable import DBCore

/// Runs against a real server. Enable with e.g.
/// `DBEXPLORER_TEST_DATABASE_URL=postgresql://postgres:postgres@localhost:5432/postgres?sslmode=disable swift test`
/// (see `scripts/test-integration.sh`, which starts `postgres:18` in Docker).
private let databaseURL = ProcessInfo.processInfo.environment["DBEXPLORER_TEST_DATABASE_URL"]

@Suite(.enabled(if: databaseURL != nil), .serialized)
struct IntegrationTests {
    func makeSession() async throws -> DatabaseSession {
        let parsed = try ConnectionString.parse(databaseURL!)
        let session = DatabaseSession(config: parsed.config, secrets: .init(password: parsed.password))
        try await session.connect()
        return session
    }

    func withTable(_ body: (DatabaseSession, TableStructure) async throws -> Void) async throws {
        let session = try await makeSession()
        let schema = "dbexplorer_test_\(UInt32.random(in: 0...UInt32.max))"
        _ = try await session.rows("CREATE SCHEMA \(schema)")
        _ = try await session.rows("""
            CREATE TABLE \(schema).items (
                id serial PRIMARY KEY, name text NOT NULL, price numeric(10,2), tags text[],
                created timestamptz DEFAULT now(), doubled int GENERATED ALWAYS AS (id * 2) STORED)
            """)
        _ = try await session.rows("INSERT INTO \(schema).items (name, price, tags) SELECT 'item ' || g, g * 1.5, ARRAY['a','b'] FROM generate_series(1, 30) g")
        _ = try await session.rows("CREATE TABLE \(schema).nopk (v text)")
        _ = try await session.rows("INSERT INTO \(schema).nopk VALUES ('x'), ('y')")
        _ = try await session.rows("CREATE VIEW \(schema).cheap AS SELECT * FROM \(schema).items WHERE price < 10")
        func cleanUp() async {
            _ = try? await session.rows("DROP SCHEMA \(schema) CASCADE")
            await session.close()
        }
        do {
            let relations = try await session.relations(schema: schema)
            #expect(relations.map(\.name) == ["cheap", "items", "nopk"])
            #expect(relations.map(\.kind) == [.view, .table, .table])
            let items = try await session.structure(of: relations[1])
            try await body(session, items)
        } catch {
            await cleanUp()
            throw error
        }
        await cleanUp()
    }

    @Test func connectAndIntrospect() async throws {
        let session = try await makeSession()
        let schemas = try await session.schemas(includeSystem: false)
        #expect(schemas.contains { $0.name == "public" })
        #expect(!schemas.contains { $0.name == "pg_catalog" })
        #expect(try await session.databases().isEmpty == false)
        await session.close()
    }

    @Test func structureAndPaging() async throws {
        try await withTable { session, items in
            #expect(items.columns.map(\.name) == ["id", "name", "price", "tags", "created", "doubled"])
            #expect(items.primaryKey.map(\.name) == ["id"])
            #expect(items.columns[2].dataType == "numeric(10,2)")
            #expect(items.columns[5].isGenerated)
            #expect(items.indexes.contains { $0.isPrimary })

            var query = TableQuery(structure: items, sort: .init(column: "id", ascending: false), pageSize: 10, page: 1)
            let page = try await session.fetchPage(query)
            #expect(page.count == 10)
            #expect(page.first?.values[0] == .text("20"))
            #expect(page.first?.values[3] == .text("{a,b}"))
            query.filter = "price > 40"
            #expect(try await session.exactCount(query) == 4)
        }
    }

    @Test func transactionalSave() async throws {
        try await withTable { session, items in
            let rows = try await session.fetchPage(TableQuery(structure: items))
            var changes = ChangeSet()
            changes.set(.text("renamed"), row: rows[0], column: 1)
            changes.set(.null, row: rows[0], column: 2)
            changes.deletes = [rows[1].id]
            changes.inserts = [NewRow(id: -1, values: [.default, .text("new"), .text("9.99"), .text("{z}"), .default, .default])]
            try await session.apply(try ChangeSetSQL.statements(for: changes, structure: items, rows: rows))

            let after = try await session.fetchPage(TableQuery(structure: items))
            #expect(after.count == 30)
            #expect(after[0].values[1] == .text("renamed"))
            #expect(after[0].values[2] == .null)
            #expect(after.last?.values[1] == .text("new"))

            // A statement touching 0 rows rolls back the whole save.
            var bad = ChangeSet()
            bad.set(.text("should not stick"), row: after[0], column: 1)
            var statements = try ChangeSetSQL.statements(for: bad, structure: items, rows: after)
            statements.append(BoundStatement(sql: "DELETE FROM \(items.relation.qualifiedName) WHERE id = -1"))
            await #expect(throws: DatabaseError.self) { try await session.apply(statements) }
            let unchanged = try await session.fetchPage(TableQuery(structure: items))
            #expect(unchanged[0].values[1] == .text("renamed"))
        }
    }

    @Test func ctidEditing() async throws {
        try await withTable { session, items in
            let nopk = try await session.relations(schema: items.relation.schema).first { $0.name == "nopk" }!
            let structure = try await session.structure(of: nopk)
            #expect(structure.rowIdentity == .ctid)
            let rows = try await session.fetchPage(TableQuery(structure: structure))
            #expect(rows.allSatisfy { $0.ctid != nil })
            var changes = ChangeSet()
            changes.set(.text("z"), row: rows[0], column: 0)
            try await session.apply(try ChangeSetSQL.statements(for: changes, structure: structure, rows: rows))
            let values = try await session.rows("SELECT v FROM \(nopk.qualifiedName) ORDER BY v")
            #expect(values.map { $0[0] } == [.text("y"), .text("z")])
        }
    }

    @Test func queryConnection() async throws {
        let session = try await makeSession()
        let connection = try await session.makeQueryConnection()
        #expect(connection.backendPID > 0)

        let select = try await connection.execute("SELECT 1::int AS a, 'x'::text AS b, 1.50::numeric AS c, '2024-02-29'::date AS d, NULL::int AS e")
        #expect(select.command == "SELECT")
        #expect(select.rowCount == 1)
        #expect(select.resultSet.columns.map(\.name) == ["a", "b", "c", "d", "e"])
        #expect(select.resultSet.rows[0].values == [.text("1"), .text("x"), .text("1.50"), .text("2024-02-29"), .null])

        _ = try await connection.execute("CREATE TEMP TABLE t (v int)")
        _ = try await connection.execute("BEGIN")
        let insert = try await connection.execute("INSERT INTO t SELECT generate_series(1, 5)")
        #expect(insert.command == "INSERT")
        #expect(insert.rowCount == 5)
        _ = try await connection.execute("ROLLBACK")
        #expect(try await connection.execute("SELECT count(*) FROM t").resultSet.rows[0].values == [.text("0")])

        do {
            _ = try await connection.execute("SELECT * FROM does_not_exist")
            Issue.record("expected an error")
        } catch {
            #expect(error.sqlState == "42P01")
            #expect(error.position == 15)
        }

        // Server-side cancellation.
        let running = Task { try await connection.execute("SELECT pg_sleep(10)") }
        try await Task.sleep(for: .milliseconds(300))
        try await session.cancelBackend(pid: connection.backendPID)
        do {
            _ = try await running.value
            Issue.record("expected cancellation")
        } catch let error as DatabaseError {
            #expect(error.kind == .cancelled)
        }

        await connection.close()
        await session.close()
    }
}
