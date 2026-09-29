import Testing
@testable import DBCore

@Suite struct ConnectionStringTests {
    @Test func fullURI() throws {
        let p = try ConnectionString.parse("postgresql://alice:s3cret@db.example.com:6543/sales?sslmode=require&application_name=app&connect_timeout=5")
        #expect(p.config.user == "alice")
        #expect(p.password == "s3cret")
        #expect(p.config.host == "db.example.com")
        #expect(p.config.port == 6543)
        #expect(p.config.database == "sales")
        #expect(p.config.tlsMode == .require)
        #expect(p.config.applicationName == "app")
        #expect(p.config.connectTimeout == 5)
        #expect(p.unknownParameters.isEmpty)
    }

    @Test func postgresSchemeAndDefaults() throws {
        let p = try ConnectionString.parse("postgres://localhost")
        #expect(p.config.host == "localhost")
        #expect(p.config.port == 5432)
        #expect(p.config.database == "")
        #expect(p.config.user == "")
        #expect(p.password == nil)
        #expect(p.config.tlsMode == .prefer)
    }

    @Test func percentDecoding() throws {
        let p = try ConnectionString.parse("postgresql://us%40er:p%3Ass%2Fw@host/my%20db")
        #expect(p.config.user == "us@er")
        #expect(p.password == "p:ss/w")
        #expect(p.config.database == "my db")
    }

    @Test func ipv6Host() throws {
        let p = try ConnectionString.parse("postgresql://[::1]:5433/db")
        #expect(p.config.host == "::1")
        #expect(p.config.port == 5433)
        let q = try ConnectionString.parse("postgresql://[2001:db8::1]/db")
        #expect(q.config.host == "2001:db8::1")
        #expect(q.config.port == 5432)
    }

    @Test func unixSocketHostParam() throws {
        let p = try ConnectionString.parse("postgresql:///mydb?host=/var/run/postgresql")
        #expect(p.config.host == "/var/run/postgresql")
        #expect(p.config.isUnixSocket)
        #expect(p.config.unixSocketPath == "/var/run/postgresql/.s.PGSQL.5432")
        #expect(p.config.database == "mydb")
    }

    @Test func unknownParametersKept() throws {
        let p = try ConnectionString.parse("postgresql://h/db?sslmode=disable&target_session_attrs=any&sslrootcert=/tmp/ca.pem")
        #expect(p.config.tlsMode == .disable)
        #expect(p.config.sslRootCert == "/tmp/ca.pem")
        #expect(p.unknownParameters.map(\.key) == ["target_session_attrs"])
        #expect(p.warnings.count == 1)
    }

    @Test(arguments: TLSMode.allCases)
    func allSSLModes(mode: TLSMode) throws {
        let p = try ConnectionString.parse("postgresql://h?sslmode=\(mode.rawValue)")
        #expect(p.config.tlsMode == mode)
    }

    @Test func errors() {
        #expect(throws: ConnectionStringError.empty) { try ConnectionString.parse("  ") }
        #expect(throws: ConnectionStringError.invalidScheme("mysql")) { try ConnectionString.parse("mysql://h/db") }
        #expect(throws: ConnectionStringError.invalidPort("abc")) { try ConnectionString.parse("postgresql://h:abc/db") }
        #expect(throws: ConnectionStringError.invalidPort("70000")) { try ConnectionString.parse("postgresql://h:70000/db") }
        #expect(throws: ConnectionStringError.invalidSSLMode("sometimes")) { try ConnectionString.parse("postgresql://h?sslmode=sometimes") }
        #expect(throws: ConnectionStringError.invalidHost("[::1")) { try ConnectionString.parse("postgresql://[::1/db") }
    }

    @Test func keyValueForm() throws {
        let p = try ConnectionString.parse("host=db port=5433 dbname='my db' user=bob password='it\\'s' sslmode=verify-full foo=bar")
        #expect(p.config.host == "db")
        #expect(p.config.port == 5433)
        #expect(p.config.database == "my db")
        #expect(p.config.user == "bob")
        #expect(p.password == "it's")
        #expect(p.config.tlsMode == .verifyFull)
        #expect(p.unknownParameters.map(\.key) == ["foo"])
    }

    @Test func keyValueErrors() {
        #expect(throws: ConnectionStringError.unterminatedQuote) { try ConnectionString.parse("host='db") }
    }

    @Test func formatRoundTrip() throws {
        let config = ConnectionConfig(host: "db.example.com", port: 6543, database: "my db", user: "us@er", tlsMode: .verifyCA,
                                      connectTimeout: 3, applicationName: "x")
        let uri = ConnectionString.format(config, password: "p:w")
        #expect(uri == "postgresql://us%40er:p%3Aw@db.example.com:6543/my%20db?sslmode=verify-ca&connect_timeout=3&application_name=x")
        let parsed = try ConnectionString.parse(uri)
        #expect(parsed.config == config)
        #expect(parsed.password == "p:w")
    }

    @Test func formatOmitsPasswordAndDefaults() {
        let config = ConnectionConfig(host: "::1", port: 5432, database: "d", user: "u")
        #expect(ConnectionString.format(config) == "postgresql://u@[::1]/d")
        let socket = ConnectionConfig(host: "/tmp", database: "d", user: "u", tlsMode: .disable)
        #expect(ConnectionString.format(socket) == "postgresql://u@/d?host=%2Ftmp&sslmode=disable")
    }

    @Test func detection() {
        #expect(ConnectionString.looksLikeConnectionString("postgresql://h"))
        #expect(ConnectionString.looksLikeConnectionString("  POSTGRES://h"))
        #expect(ConnectionString.looksLikeConnectionString("host=a dbname=b"))
        #expect(!ConnectionString.looksLikeConnectionString("db.example.com"))
    }
}
