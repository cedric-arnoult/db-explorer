import Foundation

public struct SupabaseProjectInfo: Sendable, Hashable, Decodable {
    public struct Database: Sendable, Hashable, Decodable {
        public var host: String
        public var version: String?
    }
    public var ref: String
    public var name: String
    public var region: String
    public var status: String?
    public var database: Database?
}

/// A Supavisor pooler entry of `GET /v1/projects/{ref}/config/database/pooler`.
public struct SupabasePooler: Sendable, Hashable, Decodable {
    public var databaseType: String
    public var dbUser: String
    public var dbHost: String
    public var dbPort: Int
    public var dbName: String
    public var poolMode: String?

    enum CodingKeys: String, CodingKey {
        case databaseType = "database_type", dbUser = "db_user", dbHost = "db_host", dbPort = "db_port"
        case dbName = "db_name", poolMode = "pool_mode"
    }
}

public struct SupabaseAPIKey: Sendable, Hashable, Decodable {
    public var name: String
    public var type: String?
    public var apiKey: String?

    enum CodingKeys: String, CodingKey { case name, type, apiKey = "api_key" }
}

/// Temporary Postgres credentials from `POST /v1/projects/{ref}/cli/login-role`, as used by `supabase --linked`.
public struct SupabaseLoginRole: Sendable, Hashable, Decodable {
    public var role: String
    public var password: String
    public var ttlSeconds: Int?

    enum CodingKeys: String, CodingKey { case role, password, ttlSeconds = "ttl_seconds" }
}

/// A deployed Edge Function, with every field returned by the API kept verbatim.
public struct SupabaseFunction: Sendable, Hashable, Identifiable {
    public var slug: String
    public var fields: [KeyValue]
    public var id: String { slug }
    public init(slug: String, fields: [KeyValue]) {
        self.slug = slug
        self.fields = fields
    }
}

/// Client for the Supabase Management API (`https://api.supabase.com/v1`), authenticated with a personal access token.
public struct SupabaseAPI: Sendable {
    public var accessToken: String
    public var baseURL: URL
    private let urlSession: URLSession

    public init(accessToken: String, baseURL: URL = URL(string: "https://api.supabase.com")!, urlSession: URLSession = .shared) {
        self.accessToken = accessToken
        self.baseURL = baseURL
        self.urlSession = urlSession
    }

    public func project(_ ref: String) async throws(DatabaseError) -> SupabaseProjectInfo {
        try decode(try await send("GET", "v1/projects/\(ref)"))
    }

    public func poolers(_ ref: String) async throws(DatabaseError) -> [SupabasePooler] {
        try decode(try await send("GET", "v1/projects/\(ref)/config/database/pooler"))
    }

    public func apiKeys(_ ref: String) async throws(DatabaseError) -> [SupabaseAPIKey] {
        try decode(try await send("GET", "v1/projects/\(ref)/api-keys"))
    }

    public func createLoginRole(_ ref: String, readOnly: Bool = false) async throws(DatabaseError) -> SupabaseLoginRole {
        try decode(try await send("POST", "v1/projects/\(ref)/cli/login-role", body: ["read_only": readOnly]))
    }

    public func functions(_ ref: String) async throws(DatabaseError) -> [SupabaseFunction] {
        let data = try await send("GET", "v1/projects/\(ref)/functions")
        guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw DatabaseError(kind: .other, message: "Unexpected response from the Supabase API.")
        }
        return list.map { object in
            SupabaseFunction(
                slug: object["slug"] as? String ?? "",
                fields: object.keys.sorted().map { KeyValue(key: $0, value: Self.describe(object[$0]!)) })
        }
        .sorted { $0.slug < $1.slug }
    }

    static func describe(_ value: Any) -> String {
        if value is NSNull { return "null" }
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return CFGetTypeID(n) == CFBooleanGetTypeID() ? (n.boolValue ? "true" : "false") : n.stringValue }
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]) {
            return String(decoding: data, as: UTF8.self)
        }
        return String(describing: value)
    }

    private func send(_ method: String, _ path: String, body: [String: Bool]? = nil) async throws(DatabaseError) -> Data {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        let data: Data, response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            throw DatabaseError(kind: .connection, message: "Supabase API request failed: \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else { throw DatabaseError(kind: .other, message: "Invalid Supabase API response.") }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String
            throw DatabaseError(kind: .server, message: "Supabase API error \(http.statusCode): \(message ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode))",
                                detail: "\(method) \(path)")
        }
        return data
    }

    private func decode<T: Decodable>(_ data: Data) throws(DatabaseError) -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw DatabaseError(kind: .other, message: "Unexpected response from the Supabase API: \(error)")
        }
    }
}

/// Maps a Supabase project onto its low-level services: a Postgres server and an S3 endpoint.
public enum SupabaseProject {
    /// Extracts a project ref from a ref, project URL, dashboard URL, database host or pooler user name.
    public static func projectRef(from input: String) -> String? {
        input.split { !($0.isASCII && ($0.isLowercase || $0.isNumber)) }
            .first { $0.count == 20 }
            .map(String.init)
    }

    /// Postgres through the Supavisor pooler in session mode (port 5432), which keeps `BEGIN`/`COMMIT`
    /// across statements and works over IPv4, unlike the direct `db.<ref>.supabase.co` host (IPv6-only).
    /// Pooler user names are `<role>.<ref>`. Keeps `config.database` when set.
    public static func applyPooler(_ pooler: SupabasePooler, role: String, projectRef: String, to config: inout ConnectionConfig) {
        config.host = pooler.dbHost
        config.port = 5432
        config.user = "\(role).\(projectRef)"
        if config.database.isEmpty { config.database = pooler.dbName }
        config.tlsMode = .require
        config.sshTunnel = nil
        // The temporary CLI login role is NOINHERIT: it only gets privileges (and BYPASSRLS) after `SET ROLE postgres`.
        config.sessionRole = "postgres"
    }

    /// Resolves the Postgres server of a Supabase connection with nothing but the access token:
    /// the pooler address, and a temporary login role created through the Management API.
    public static func resolvePostgres(
        _ config: ConnectionConfig, accessToken: String
    ) async throws(DatabaseError) -> (config: ConnectionConfig, password: String, region: String) {
        guard let ref = config.supabase?.projectRef, !ref.isEmpty else {
            throw DatabaseError(kind: .connection, message: "No Supabase project.")
        }
        let api = SupabaseAPI(accessToken: accessToken)
        let project = try await api.project(ref)
        guard let pooler = try await api.poolers(ref).first(where: { $0.databaseType == "PRIMARY" }) else {
            throw DatabaseError(kind: .connection, message: "The project has no connection pooler.")
        }
        let login = try await api.createLoginRole(ref)
        var resolved = config
        applyPooler(pooler, role: login.role, projectRef: ref, to: &resolved)
        resolved.supabase?.region = project.region
        return (resolved, login.password, project.region)
    }

    public static func s3Endpoint(projectRef: String) -> URL {
        URL(string: "https://\(projectRef).storage.supabase.co/storage/v1/s3")!
    }

    /// An S3 client for the project's Storage, signed the way Supabase documents for session tokens:
    /// access key = project ref, secret = anon key, session token = service_role JWT (bypasses Row Level Security).
    public static func storageClient(_ supabase: SupabaseConfig, accessToken: String) async throws(DatabaseError) -> S3Client {
        let ref = supabase.projectRef
        let api = SupabaseAPI(accessToken: accessToken)
        var region = supabase.region
        if region == nil { region = try await api.project(ref).region }
        let keys = try await api.apiKeys(ref)
        guard let anon = keys.first(where: { $0.name == "anon" })?.apiKey, anon.hasPrefix("ey"),
              let serviceRole = keys.first(where: { $0.name == "service_role" })?.apiKey, serviceRole.hasPrefix("ey") else {
            throw DatabaseError(kind: .connection, message: "Storage needs the project's legacy JWT API keys (anon and service_role).")
        }
        return S3Client(endpoint: s3Endpoint(projectRef: ref), region: region ?? "us-east-1",
                        credentials: S3Credentials(accessKeyID: ref, secretAccessKey: anon, sessionToken: serviceRole))
    }
}
