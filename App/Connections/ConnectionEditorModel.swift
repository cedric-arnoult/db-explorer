import Foundation
import DBCore
import OSLog

/// State of the connection editor sheet: a Postgres server, or a Supabase project.
@Observable
final class ConnectionEditorModel {
    enum Kind: String, CaseIterable, Identifiable {
        case postgres = "Postgres"
        case supabase = "Supabase"
        var id: String { rawValue }
    }

    enum TestState: Equatable {
        case idle
        case testing
        case success(String)
        case failure(String)
    }

    let id: UUID
    let isNew: Bool
    var kind: Kind = .postgres
    /// Edited by the form. Every change is mirrored into `connectionString`.
    var config: ConnectionConfig {
        didSet { if !isApplyingString { refreshConnectionString() } }
    }
    var password: String
    var sshPassword: String
    var projectRef = ""
    var supabaseToken: String
    /// Two-way with the form: typing or pasting a valid string fills the form.
    var connectionString = "" {
        didSet { if !isRefreshingString { applyConnectionString() } }
    }
    var parseError: String?
    var warnings: [String] = []
    var testState: TestState = .idle
    private var isApplyingString = false
    private var isRefreshingString = false

    var useSSH: Bool {
        get { config.sshTunnel != nil }
        set { config.sshTunnel = newValue ? (config.sshTunnel ?? SSHTunnelConfig()) : nil }
    }

    var ssh: SSHTunnelConfig {
        get { config.sshTunnel ?? SSHTunnelConfig() }
        set { config.sshTunnel = newValue }
    }

    init(connection: SavedConnection?) {
        if let connection {
            id = connection.id
            isNew = false
            config = connection.config
            password = Keychain.password(for: connection.id) ?? ""
            sshPassword = Keychain.password(for: connection.id, kind: .ssh) ?? ""
            supabaseToken = Keychain.password(for: connection.id, kind: .supabaseToken) ?? ""
        } else {
            id = UUID()
            isNew = true
            config = ConnectionConfig(name: "", host: "localhost", user: NSUserName())
            password = ""
            sshPassword = ""
            supabaseToken = ""
        }
        kind = config.supabase == nil ? .postgres : .supabase
        projectRef = config.supabase?.projectRef ?? ""
        refreshConnectionString()
    }

    /// Copy of an existing connection with a fresh id.
    init(duplicating connection: SavedConnection) {
        id = UUID()
        isNew = true
        var copy = connection.config
        copy.name += " Copy"
        config = copy
        password = Keychain.password(for: connection.id) ?? ""
        sshPassword = Keychain.password(for: connection.id, kind: .ssh) ?? ""
        supabaseToken = Keychain.password(for: connection.id, kind: .supabaseToken) ?? ""
        kind = copy.supabase == nil ? .postgres : .supabase
        projectRef = copy.supabase?.projectRef ?? ""
        refreshConnectionString()
    }

    var canSave: Bool {
        switch kind {
        case .postgres: !config.host.isEmpty || !config.database.isEmpty
        case .supabase: !projectRef.isEmpty && !supabaseToken.isEmpty
        }
    }

    /// The config to save for the selected kind. Supabase connections keep no server fields.
    var resultingConfig: ConnectionConfig {
        switch kind {
        case .postgres:
            var result = config
            result.supabase = nil
            return result
        case .supabase:
            return ConnectionConfig(name: config.name, host: "", database: "", colorTag: config.colorTag,
                                    supabase: SupabaseConfig(projectRef: projectRef))
        }
    }

    private func refreshConnectionString() {
        isRefreshingString = true
        connectionString = ConnectionString.format(config)
        isRefreshingString = false
        parseError = nil
        warnings = []
    }

    /// Parses `connectionString` into the form. The password goes to the password field (and later the Keychain).
    private func applyConnectionString() {
        guard !connectionString.trimmingCharacters(in: .whitespaces).isEmpty else {
            parseError = nil
            return
        }
        do {
            let parsed = try ConnectionString.parse(connectionString)
            var newConfig = parsed.config
            newConfig.name = config.name
            newConfig.colorTag = config.colorTag
            newConfig.sshTunnel = config.sshTunnel
            if newConfig.host.isEmpty { newConfig.host = "localhost" }
            isApplyingString = true
            config = newConfig
            isApplyingString = false
            if let pw = parsed.password { password = pw }
            warnings = parsed.warnings
            parseError = nil
        } catch {
            parseError = error.errorDescription
        }
    }

    /// Accepts a project URL, dashboard URL or connection string in the project field.
    func projectRefChanged(_ newValue: String) {
        if let ref = SupabaseProject.projectRef(from: newValue), ref != newValue { projectRef = ref }
    }

    func test() async {
        testState = .testing
        do {
            switch kind {
            case .postgres:
                let version = try await DatabaseSession.test(
                    config: config,
                    secrets: ConnectionSecrets(password: password.nilIfEmpty, sshPassword: sshPassword.nilIfEmpty),
                    hostKeyValidator: { host, key in KnownHosts.validate(host: host, key: key) })
                testState = .success(version)
            case .supabase:
                let project = try await SupabaseAPI(accessToken: supabaseToken).project(projectRef)
                if config.name.isEmpty { config.name = project.name }
                testState = .success("\(project.name) · \(project.region) · \(project.status ?? "")")
            }
        } catch {
            appLogger.error("Test connection failed: \(error.fullDescription, privacy: .public)")
            testState = .failure(error.fullDescription)
        }
    }

    func save(into connection: SavedConnection) {
        connection.config = resultingConfig
        switch kind {
        case .postgres:
            Keychain.setPassword(password, for: connection.id)
            Keychain.setPassword(useSSH ? sshPassword : nil, for: connection.id, kind: .ssh)
            Keychain.setPassword(nil, for: connection.id, kind: .supabaseToken)
        case .supabase:
            Keychain.setPassword(nil, for: connection.id)
            Keychain.setPassword(nil, for: connection.id, kind: .ssh)
            Keychain.setPassword(supabaseToken, for: connection.id, kind: .supabaseToken)
        }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
