import Foundation
import Logging
import NIOConcurrencyHelpers
import NIOCore
import PostgresNIO

/// Secrets needed to open a session. Never persisted outside the Keychain.
public struct ConnectionSecrets: Sendable {
    public var password: String?
    public var sshPassword: String?
    /// Supabase personal access token, for the Management API.
    public var supabaseAccessToken: String?

    public init(password: String? = nil, sshPassword: String? = nil, supabaseAccessToken: String? = nil) {
        self.password = password
        self.sshPassword = sshPassword
        self.supabaseAccessToken = supabaseAccessToken
    }
}

/// Owns a `PostgresClient` (connection pool) for one database.
public actor DatabaseSession {
    public nonisolated let config: ConnectionConfig
    private let secrets: ConnectionSecrets
    private let hostKeyValidator: SSHHostKeyValidator
    private var client: PostgresClient?
    private var runTask: Task<Void, Never>?
    private var tunnel: SSHTunnel?
    /// Pooled connections on which `config.sessionRole` was already set.
    private var roleSetConnections: Set<PostgresConnection.ID> = []
    private let logger = Logger(label: "DBExplorer.session")

    public init(
        config: ConnectionConfig,
        secrets: ConnectionSecrets,
        hostKeyValidator: @escaping SSHHostKeyValidator = { _, _ in true }
    ) {
        self.config = config
        self.secrets = secrets
        self.hostKeyValidator = hostKeyValidator
    }

    /// Opens the pool and checks the server responds. Returns `SELECT version()`.
    @discardableResult
    public func connect() async throws(DatabaseError) -> String {
        if client == nil {
            var host: String?
            var port: Int?
            if let ssh = config.sshTunnel, !ssh.host.isEmpty {
                do {
                    let t = try await SSHTunnel.open(
                        config: ssh, password: secrets.sshPassword ?? "",
                        targetHost: config.host.isEmpty ? "localhost" : config.host, targetPort: config.port,
                        hostKeyValidator: hostKeyValidator)
                    tunnel = t
                    host = "127.0.0.1"
                    port = t.localPort
                } catch {
                    throw DatabaseError(kind: .connection, message: DatabaseError(error).message)
                }
            }
            let configuration: PostgresClient.Configuration
            do {
                configuration = try PostgresConfiguration.client(config, password: secrets.password, host: host, port: port)
            } catch {
                throw DatabaseError(kind: .connection, message: "Invalid TLS configuration: \(DatabaseError(error).message)")
            }
            let client = PostgresClient(configuration: configuration)
            self.client = client
            runTask = Task { await client.run() }
        }
        do {
            let timeout = PostgresConfiguration.connectTimeout(for: config) + .seconds(2)
            return try await withTimeout(timeout) { [self] () async throws(DatabaseError) -> String in
                let rows = try await self.rows("SELECT version()")
                return rows.first?.first?.text ?? ""
            }
        } catch {
            await close()
            throw error
        }
    }

    public func close() async {
        runTask?.cancel()
        runTask = nil
        client = nil
        await tunnel?.close()
        tunnel = nil
    }

    /// Opens a session, runs `SELECT version()` and closes it.
    public static func test(
        config: ConnectionConfig, secrets: ConnectionSecrets,
        hostKeyValidator: @escaping SSHHostKeyValidator = { _, _ in true }
    ) async throws(DatabaseError) -> String {
        let session = DatabaseSession(config: config, secrets: secrets, hostKeyValidator: hostKeyValidator)
        let version = try await session.connect()
        await session.close()
        return version
    }

    // MARK: Queries

    private func requireClient() throws(DatabaseError) -> PostgresClient {
        guard let client else { throw .notConnected }
        return client
    }

    /// Runs a query and decodes every cell as text.
    public func rows(_ sql: String, binds: [String?] = []) async throws(DatabaseError) -> [[CellValue]] {
        try await resultSet(sql, binds: binds).rows.map(\.values)
    }

    public func resultSet(_ sql: String, binds: [String?] = []) async throws(DatabaseError) -> ResultSet {
        let logger = self.logger
        do {
            return try await withConnection { connection in
                let sequence = try await connection.query(Self.query(sql, binds), logger: logger)
                var rows: [ResultRow] = []
                for try await row in sequence {
                    rows.append(ResultRow(id: rows.count, values: row.map(Self.decode)))
                }
                let columns = sequence.columns.enumerated().map {
                    ResultColumn(index: $0.offset, name: $0.element.name, typeOID: $0.element.dataType.rawValue)
                }
                return ResultSet(columns: columns, rows: rows)
            }
        } catch {
            throw DatabaseError(error)
        }
    }

    /// Leases a pooled connection, switching it to `config.sessionRole` the first time it is used.
    private func withConnection<T: Sendable>(_ body: (PostgresConnection) async throws -> T) async throws -> T {
        let client = try requireClient()
        return try await client.withConnection { connection in
            if let role = config.sessionRole, !roleSetConnections.contains(connection.id) {
                try await connection.query(PostgresQuery(unsafeSQL: Self.setRoleSQL(role)), logger: logger)
                roleSetConnections.insert(connection.id)
            }
            return try await body(connection)
        }
    }

    static func setRoleSQL(_ role: String) -> String {
        "SET ROLE \(SQLIdentifier.quote(role))"
    }

    static func query(_ sql: String, _ binds: [String?]) -> PostgresQuery {
        var bindings = PostgresBindings(capacity: binds.count)
        for bind in binds {
            if let bind { bindings.append(bind) } else { bindings.appendNull() }
        }
        return PostgresQuery(unsafeSQL: sql, binds: bindings)
    }

    static func decode(_ cell: PostgresCell) -> CellValue {
        guard let bytes = cell.bytes else { return .null }
        if cell.format == .text { return .text(String(buffer: bytes)) }
        return CellDecoder.decode(oid: cell.dataType.rawValue, bytes: Array(buffer: bytes))
    }

    // MARK: Introspection

    public func databases() async throws(DatabaseError) -> [DatabaseInfo] {
        CatalogQueries.parseDatabases(try await rows(CatalogQueries.databases))
    }

    public func schemas(includeSystem: Bool) async throws(DatabaseError) -> [SchemaInfo] {
        let all = CatalogQueries.parseSchemas(try await rows(CatalogQueries.schemas))
        return includeSystem ? all : all.filter { !$0.isSystem }
    }

    public func relations(schema: String) async throws(DatabaseError) -> [RelationInfo] {
        CatalogQueries.parseRelations(try await rows(CatalogQueries.relations, binds: [schema]))
    }

    public func structure(of relation: RelationInfo) async throws(DatabaseError) -> TableStructure {
        let oid = String(relation.oid)
        let current = CatalogQueries.parseRelations(try await rows(CatalogQueries.relation, binds: [oid])).first ?? relation
        return TableStructure(
            relation: current,
            columns: CatalogQueries.parseColumns(try await rows(CatalogQueries.columns, binds: [oid])),
            indexes: CatalogQueries.parseIndexes(try await rows(CatalogQueries.indexes, binds: [oid])),
            constraints: CatalogQueries.parseConstraints(try await rows(CatalogQueries.constraints, binds: [oid]))
        )
    }

    // MARK: Table data

    public func fetchPage(_ query: TableQuery) async throws(DatabaseError) -> [TableRow] {
        let result = try await rows(query.selectSQL)
        let offset = query.page * query.pageSize
        return result.enumerated().map { index, values in
            if query.includesCTID {
                return TableRow(id: offset + index, ctid: values.first?.text, values: Array(values.dropFirst()))
            }
            return TableRow(id: offset + index, values: values)
        }
    }

    public func exactCount(_ query: TableQuery) async throws(DatabaseError) -> Int {
        Int(try await rows(query.countSQL).first?.first?.text ?? "") ?? 0
    }

    /// Runs statements in one transaction; each must affect exactly one row or everything is rolled back.
    public func apply(_ statements: [BoundStatement]) async throws(DatabaseError) {
        let logger = self.logger
        do {
            try await withConnection { connection in try await connection.withTransaction(logger: logger) { connection in
                for statement in statements {
                    let result = try await connection.query(Self.query(statement.sql, statement.binds), logger: logger).get()
                    let affected = result.metadata.rows ?? 0
                    if affected != 1 {
                        throw DatabaseError(
                            kind: .unexpectedRowCount(expected: 1, actual: affected),
                            message: "Expected 1 row to be affected but \(affected) were. All changes were rolled back.",
                            detail: statement.sql)
                    }
                }
            } }
        } catch {
            throw DatabaseError(error)
        }
    }

    // MARK: SQL editor

    /// Opens a dedicated connection for a query editor tab (so `BEGIN`/`COMMIT` span executions).
    public func makeQueryConnection() async throws(DatabaseError) -> QueryConnection {
        var host: String?, port: Int?
        if let tunnel { host = "127.0.0.1"; port = tunnel.localPort }
        do {
            let configuration = try PostgresConfiguration.connection(config, password: secrets.password, host: host, port: port)
            let connection = try await PostgresConnection.connect(
                configuration: configuration, id: Int.random(in: 1...Int(Int32.max)), logger: logger)
            if let role = config.sessionRole {
                try await connection.query(PostgresQuery(unsafeSQL: Self.setRoleSQL(role)), logger: logger)
            }
            return try await QueryConnection(connection: connection, logger: logger)
        } catch {
            throw DatabaseError(error)
        }
    }

    /// Asks the server to cancel the query running on `pid`.
    public func cancelBackend(pid: Int32) async throws(DatabaseError) {
        _ = try await rows("SELECT pg_cancel_backend($1::int)", binds: [String(pid)])
    }
}

/// A dedicated connection used by one SQL editor tab.
public actor QueryConnection {
    private let connection: PostgresConnection
    private let logger: Logger
    public nonisolated let backendPID: Int32

    /// Maximum rows kept per result, to protect the UI.
    public static let rowLimit = 50_000

    init(connection: PostgresConnection, logger: Logger) async throws {
        self.connection = connection
        self.logger = logger
        let rows = try await connection.query("SELECT pg_backend_pid()", logger: logger).collect()
        backendPID = try rows.first?.decode(Int32.self) ?? 0
    }

    public nonisolated var isClosed: Bool { connection.isClosed }

    public func execute(_ sql: String) async throws(DatabaseError) -> StatementResult {
        let clock = ContinuousClock()
        let start = clock.now
        let collector = RowCollector(limit: Self.rowLimit)
        do {
            let metadata = try await connection.query(
                PostgresQuery(unsafeSQL: sql), logger: logger, { row in collector.append(row) }
            ).get()
            let (columns, rows, total) = collector.result
            let count = metadata.rows ?? (columns.isEmpty ? nil : total)
            return StatementResult(
                command: metadata.command, rowCount: count,
                resultSet: ResultSet(columns: columns, rows: rows),
                duration: clock.now - start, isTruncated: total > rows.count)
        } catch {
            throw DatabaseError(error)
        }
    }

    public func close() async {
        try? await connection.close()
    }
}

/// Thread-safe accumulator used by the callback-based query API.
private final class RowCollector: Sendable {
    private struct State {
        var columns: [ResultColumn] = []
        var rows: [ResultRow] = []
        var total = 0
    }
    private let state = NIOLockedValueBox(State())
    private let limit: Int

    init(limit: Int) { self.limit = limit }

    func append(_ row: PostgresRow) {
        state.withLockedValue { s in
            if s.total == 0 {
                s.columns = row.enumerated().map {
                    ResultColumn(index: $0.offset, name: $0.element.columnName, typeOID: $0.element.dataType.rawValue)
                }
            }
            if s.rows.count < limit {
                s.rows.append(ResultRow(id: s.total, values: row.map(DatabaseSession.decode)))
            }
            s.total += 1
        }
    }

    var result: ([ResultColumn], [ResultRow], Int) {
        state.withLockedValue { ($0.columns, $0.rows, $0.total) }
    }
}

/// Races `operation` against a timeout.
func withTimeout<T: Sendable>(
    _ duration: Duration, _ operation: @escaping @Sendable () async throws(DatabaseError) -> T
) async throws(DatabaseError) -> T {
    do {
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: duration)
                throw DatabaseError.timeout
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    } catch {
        throw DatabaseError(error)
    }
}
