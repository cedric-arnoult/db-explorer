import Foundation
import DBCore
import SwiftData

@Model
final class SavedConnection {
    @Attribute(.unique) var id: UUID
    var name: String
    var host: String
    var port: Int
    var database: String
    var user: String
    var tlsModeRaw: String
    var connectTimeout: Int?
    var applicationName: String?
    var sslRootCert: String?
    var colorTag: String?
    var sshEnabled: Bool
    var sshHost: String
    var sshPort: Int
    var sshUser: String
    var supabaseRef: String?
    var supabaseRegion: String?
    var createdAt: Date
    var lastUsedAt: Date?

    init(id: UUID = UUID(), config: ConnectionConfig) {
        self.id = id
        name = ""
        host = ""
        port = 5432
        database = ""
        user = ""
        tlsModeRaw = TLSMode.prefer.rawValue
        sshEnabled = false
        sshHost = ""
        sshPort = 22
        sshUser = ""
        createdAt = .now
        self.config = config
    }

    var config: ConnectionConfig {
        get {
            ConnectionConfig(
                name: name, host: host, port: port, database: database, user: user,
                tlsMode: TLSMode(rawValue: tlsModeRaw) ?? .prefer,
                connectTimeout: connectTimeout, applicationName: applicationName, sslRootCert: sslRootCert,
                colorTag: colorTag,
                sshTunnel: sshEnabled ? SSHTunnelConfig(host: sshHost, port: sshPort, user: sshUser) : nil,
                supabase: supabaseRef.map { SupabaseConfig(projectRef: $0, region: supabaseRegion) })
        }
        set {
            name = newValue.name
            host = newValue.host
            port = newValue.port
            database = newValue.database
            user = newValue.user
            tlsModeRaw = newValue.tlsMode.rawValue
            connectTimeout = newValue.connectTimeout
            applicationName = newValue.applicationName
            sslRootCert = newValue.sslRootCert
            colorTag = newValue.colorTag
            sshEnabled = newValue.sshTunnel != nil
            sshHost = newValue.sshTunnel?.host ?? ""
            sshPort = newValue.sshTunnel?.port ?? 22
            sshUser = newValue.sshTunnel?.user ?? ""
            supabaseRef = newValue.supabase?.projectRef
            supabaseRegion = newValue.supabase?.region
        }
    }

    var displayName: String { name.isEmpty ? config.summary : name }
}

/// One executed SQL statement, kept per connection.
@Model
final class QueryHistoryItem {
    var connectionID: UUID
    var sql: String
    var executedAt: Date
    var durationSeconds: Double
    var succeeded: Bool

    init(connectionID: UUID, sql: String, executedAt: Date = .now, durationSeconds: Double, succeeded: Bool) {
        self.connectionID = connectionID
        self.sql = sql
        self.executedAt = executedAt
        self.durationSeconds = durationSeconds
        self.succeeded = succeeded
    }
}
