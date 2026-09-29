import Foundation
import NIOSSL
import PostgresNIO

/// Maps a `ConnectionConfig` onto PostgresNIO configurations.
enum PostgresConfiguration {
    static func tlsConfiguration(for config: ConnectionConfig) throws -> TLSConfiguration? {
        var tls = TLSConfiguration.makeClientConfiguration()
        switch config.tlsMode {
        case .disable:
            return nil
        case .allow, .prefer, .require:
            // Like libpq: encryption without certificate verification.
            tls.certificateVerification = .none
        case .verifyCA:
            tls.certificateVerification = .noHostnameVerification
        case .verifyFull:
            tls.certificateVerification = .fullVerification
        }
        if let path = config.sslRootCert, !path.isEmpty, config.tlsMode == .verifyCA || config.tlsMode == .verifyFull {
            let expanded = (path as NSString).expandingTildeInPath
            tls.trustRoots = .certificates(try NIOSSLCertificate.fromPEMFile(expanded))
        }
        return tls
    }

    static func startupParameters(for config: ConnectionConfig) -> [(String, String)] {
        [("application_name", config.applicationName.flatMap { $0.isEmpty ? nil : $0 } ?? "DB Explorer")]
    }

    static func connectTimeout(for config: ConnectionConfig) -> Duration {
        .seconds(max(config.connectTimeout ?? 10, 1))
    }

    /// `host`/`port` override the config when connecting through a tunnel.
    static func client(
        _ config: ConnectionConfig, password: String?, host: String? = nil, port: Int? = nil
    ) throws -> PostgresClient.Configuration {
        let user = config.user.isEmpty ? NSUserName() : config.user
        let database = config.database.isEmpty ? user : config.database
        var result: PostgresClient.Configuration
        if config.isUnixSocket, host == nil {
            result = .init(unixSocketPath: config.unixSocketPath, username: user, password: password, database: database)
        } else {
            let tls: PostgresClient.Configuration.TLS
            if let tlsConfig = try tlsConfiguration(for: config) {
                tls = config.tlsMode == .allow || config.tlsMode == .prefer ? .prefer(tlsConfig) : .require(tlsConfig)
            } else {
                tls = .disable
            }
            result = .init(host: host ?? effectiveHost(config), port: port ?? config.port,
                           username: user, password: password, database: database, tls: tls)
            if host != nil, !config.host.isEmpty { result.options.tlsServerName = config.host }
        }
        result.options.connectTimeout = connectTimeout(for: config)
        result.options.additionalStartupParameters = startupParameters(for: config)
        result.options.maximumConnections = 4
        result.options.connectionIdleTimeout = .seconds(300)
        return result
    }

    static func connection(
        _ config: ConnectionConfig, password: String?, host: String? = nil, port: Int? = nil
    ) throws -> PostgresConnection.Configuration {
        let user = config.user.isEmpty ? NSUserName() : config.user
        let database = config.database.isEmpty ? user : config.database
        var result: PostgresConnection.Configuration
        if config.isUnixSocket, host == nil {
            result = .init(unixSocketPath: config.unixSocketPath, username: user, password: password, database: database)
        } else {
            let tls: PostgresConnection.Configuration.TLS
            if let tlsConfig = try tlsConfiguration(for: config) {
                let context = try NIOSSLContext(configuration: tlsConfig)
                tls = config.tlsMode == .allow || config.tlsMode == .prefer ? .prefer(context) : .require(context)
            } else {
                tls = .disable
            }
            result = .init(host: host ?? effectiveHost(config), port: port ?? config.port,
                           username: user, password: password, database: database, tls: tls)
            if host != nil, !config.host.isEmpty { result.options.tlsServerName = config.host }
        }
        result.options.connectTimeout = .seconds(Int64(max(config.connectTimeout ?? 10, 1)))
        result.options.additionalStartupParameters = startupParameters(for: config)
        return result
    }

    private static func effectiveHost(_ config: ConnectionConfig) -> String {
        config.host.isEmpty ? "localhost" : config.host
    }
}
