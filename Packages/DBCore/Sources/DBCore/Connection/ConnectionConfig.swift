import Foundation

/// TLS behaviour, mirroring libpq's `sslmode`.
public enum TLSMode: String, Sendable, Codable, CaseIterable, Identifiable {
    case disable
    case allow
    case prefer
    case require
    case verifyCA = "verify-ca"
    case verifyFull = "verify-full"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .disable: "Disable"
        case .allow: "Allow"
        case .prefer: "Prefer"
        case .require: "Require"
        case .verifyCA: "Verify CA"
        case .verifyFull: "Verify Full"
        }
    }
}

/// Optional SSH tunnel used to reach the database host.
public struct SSHTunnelConfig: Sendable, Codable, Hashable {
    public var host: String
    public var port: Int
    public var user: String

    public init(host: String = "", port: Int = 22, user: String = "") {
        self.host = host
        self.port = port
        self.user = user
    }
}

/// A Supabase project. Its Postgres server, Storage (S3) and Edge Functions are all resolved at connect time
/// through the Management API, so the server fields of the connection are ignored.
public struct SupabaseConfig: Sendable, Codable, Hashable {
    public var projectRef: String
    /// AWS-style region of the project (e.g. `eu-west-1`), used to sign S3 requests. Filled at connect time.
    public var region: String?

    public init(projectRef: String = "", region: String? = nil) {
        self.projectRef = projectRef
        self.region = region
    }
}

/// Everything needed to open a connection, except secrets.
public struct ConnectionConfig: Sendable, Codable, Hashable {
    public var name: String
    /// Host name, IP address, or a Unix socket directory/path when it starts with `/`.
    public var host: String
    public var port: Int
    public var database: String
    public var user: String
    public var tlsMode: TLSMode
    public var connectTimeout: Int?
    public var applicationName: String?
    public var sslRootCert: String?
    public var colorTag: String?
    public var sshTunnel: SSHTunnelConfig?
    public var supabase: SupabaseConfig?
    /// Role set with `SET ROLE` on every new connection, for login roles that only get privileges that way.
    public var sessionRole: String?

    public init(
        name: String = "",
        host: String = "localhost",
        port: Int = 5432,
        database: String = "",
        user: String = "",
        tlsMode: TLSMode = .prefer,
        connectTimeout: Int? = nil,
        applicationName: String? = nil,
        sslRootCert: String? = nil,
        colorTag: String? = nil,
        sshTunnel: SSHTunnelConfig? = nil,
        supabase: SupabaseConfig? = nil
    ) {
        self.name = name
        self.host = host
        self.port = port
        self.database = database
        self.user = user
        self.tlsMode = tlsMode
        self.connectTimeout = connectTimeout
        self.applicationName = applicationName
        self.sslRootCert = sslRootCert
        self.colorTag = colorTag
        self.sshTunnel = sshTunnel
        self.supabase = supabase
    }

    public var isUnixSocket: Bool { host.hasPrefix("/") }

    /// Full Unix socket path: a directory gets `.s.PGSQL.<port>` appended, like libpq.
    public var unixSocketPath: String {
        host.contains(".s.PGSQL.") ? host : (host.hasSuffix("/") ? host : host + "/") + ".s.PGSQL.\(port)"
    }

    /// Short human readable description: `user@host:port/db`.
    public var summary: String {
        if let supabase { return "Supabase · \(supabase.projectRef)" }
        var s = user.isEmpty ? "" : user + "@"
        s += host.isEmpty ? "localhost" : host
        if !isUnixSocket { s += ":\(port)" }
        if !database.isEmpty { s += "/" + database }
        return s
    }
}
