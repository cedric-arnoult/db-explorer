import Foundation
import DBCore
import OSLog
import SwiftData

let appLogger = Logger(subsystem: "dev.dbexplorer.DBExplorer", category: "connection")

/// Item selectable in the sidebar.
enum SidebarItem: Hashable {
    case newQuery
    case relation(RelationInfo)
    case bucket(String)
    case edgeFunction(String)
}

/// A tab in the detail area.
enum WorkspaceTab: Identifiable {
    case relation(RelationTabModel)
    case query(QueryEditorModel)
    case bucket(BucketTabModel)
    case edgeFunction(EdgeFunctionTab)

    var id: UUID {
        switch self {
        case .relation(let m): m.id
        case .query(let m): m.id
        case .bucket(let m): m.id
        case .edgeFunction(let m): m.id
        }
    }

    var title: String {
        switch self {
        case .relation(let m): m.relation.name
        case .query(let m): m.title
        case .bucket(let m): m.bucket
        case .edgeFunction(let m): m.function.slug
        }
    }

    var systemImage: String {
        switch self {
        case .relation(let m): m.relation.kind.systemImage
        case .query: "terminal"
        case .bucket: "archivebox"
        case .edgeFunction: "function"
        }
    }

    var hasUnsavedChanges: Bool {
        if case .relation(let m) = self { return !(m.data?.changes.isEmpty ?? true) }
        return false
    }
}

/// State of one database window: session, catalog tree and open tabs.
@Observable
final class DatabaseModel {
    enum Phase {
        case idle
        case connecting
        case connected(serverVersion: String)
        case failed(DatabaseError)
    }

    let connectionID: UUID
    private(set) var config: ConnectionConfig
    private var secrets: ConnectionSecrets
    private(set) var session: DatabaseSession?
    private(set) var phase: Phase = .idle

    var schemas: [SchemaInfo] = []
    var relationsBySchema: [String: [RelationInfo]] = [:]
    var expandedSchemas: Set<String> = []
    var showSystemSchemas = false
    var sidebarFilter = ""
    var catalogError: String?

    var tabs: [WorkspaceTab] = []
    var selectedTabID: UUID?
    var sidebarSelection: SidebarItem?
    /// Storage and Edge Functions, when the connection is linked to a Supabase project.
    private(set) var supabase: SupabaseModel?

    /// Injected by the window so models can record undo and history.
    var undoManager: UndoManager?
    var modelContext: ModelContext?
    private var queryCounter = 0

    init(connectionID: UUID, config: ConnectionConfig, secrets: ConnectionSecrets) {
        self.connectionID = connectionID
        self.config = config
        self.secrets = secrets
    }

    var isConnected: Bool {
        if case .connected = phase { return true }
        return false
    }

    var serverVersion: String? {
        if case .connected(let v) = phase { return v }
        return nil
    }

    // MARK: Connection

    func connect(password: String? = nil) async {
        if let password { secrets.password = password }
        phase = .connecting
        do {
            var sessionConfig = config
            var sessionSecrets = secrets
            if config.supabase != nil {
                // Postgres credentials are temporary: resolve them again on every connect.
                let resolved = try await SupabaseProject.resolvePostgres(config, accessToken: secrets.supabaseAccessToken ?? "")
                config = resolved.config
                sessionConfig = resolved.config
                sessionSecrets.password = resolved.password
            }
            let session = DatabaseSession(
                config: sessionConfig, secrets: sessionSecrets,
                hostKeyValidator: { host, key in KnownHosts.validate(host: host, key: key) })
            let version = try await session.connect()
            self.session = session
            phase = .connected(serverVersion: version)
            if expandedSchemas.isEmpty { expandedSchemas = ["public"] }
            if supabase == nil, let supabaseConfig = config.supabase {
                supabase = SupabaseModel(config: supabaseConfig, accessToken: secrets.supabaseAccessToken ?? "")
            }
            async let catalog: Void = reloadCatalog()
            async let project: Void? = supabase?.load()
            _ = await (catalog, project)
        } catch {
            let error = DatabaseError(error)
            appLogger.error("Connect to \(self.config.summary, privacy: .public) failed: \(error.fullDescription, privacy: .public)")
            phase = .failed(error)
        }
    }

    var isSupabase: Bool { config.supabase != nil }

    func disconnect() async {
        for tab in tabs {
            if case .query(let q) = tab { await q.close() }
        }
        await session?.close()
        session = nil
    }

    // MARK: Catalog

    func reloadCatalog() async {
        guard let session else { return }
        do {
            schemas = try await session.schemas(includeSystem: showSystemSchemas)
            var relations: [String: [RelationInfo]] = [:]
            for schema in schemas where !schema.isSystem || expandedSchemas.contains(schema.name) {
                relations[schema.name] = try await session.relations(schema: schema.name)
            }
            relationsBySchema = relations
            catalogError = nil
        } catch {
            catalogError = error.fullDescription
        }
    }

    func loadRelations(schema: String) async {
        guard let session, relationsBySchema[schema] == nil else { return }
        do {
            relationsBySchema[schema] = try await session.relations(schema: schema)
        } catch {
            catalogError = error.fullDescription
        }
    }

    func filteredRelations(in schema: String) -> [RelationInfo] {
        let all = relationsBySchema[schema] ?? []
        guard !sidebarFilter.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(sidebarFilter) }
    }

    var visibleSchemas: [SchemaInfo] {
        guard !sidebarFilter.isEmpty else { return schemas }
        return schemas.filter { !filteredRelations(in: $0.name).isEmpty }
    }

    // MARK: Tabs

    func open(_ item: SidebarItem) {
        switch item {
        case .newQuery:
            newQuery()
        case .relation(let relation):
            if let existing = tabs.first(where: {
                if case .relation(let m) = $0 { return m.relation.oid == relation.oid }
                return false
            }) {
                selectedTabID = existing.id
                return
            }
            guard let session else { return }
            let model = RelationTabModel(relation: relation, session: session, owner: self)
            tabs.append(.relation(model))
            selectedTabID = model.id
            Task { await model.load() }
        case .bucket(let name):
            if let existing = tabs.first(where: {
                if case .bucket(let m) = $0 { return m.bucket == name }
                return false
            }) {
                selectedTabID = existing.id
                return
            }
            guard let client = supabase?.storage else { return }
            let model = BucketTabModel(bucket: name, client: client)
            tabs.append(.bucket(model))
            selectedTabID = model.id
            Task { await model.load() }
        case .edgeFunction(let slug):
            if let existing = tabs.first(where: {
                if case .edgeFunction(let m) = $0 { return m.function.slug == slug }
                return false
            }) {
                selectedTabID = existing.id
                return
            }
            guard let function = supabase?.functions.first(where: { $0.slug == slug }) else { return }
            let tab = EdgeFunctionTab(function: function)
            tabs.append(.edgeFunction(tab))
            selectedTabID = tab.id
        }
    }

    func newQuery(text: String = "") {
        guard let session else { return }
        queryCounter += 1
        let model = QueryEditorModel(title: "Query \(queryCounter)", text: text, session: session, owner: self)
        tabs.append(.query(model))
        selectedTabID = model.id
    }

    func close(tabID: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        if case .query(let q) = tabs[index] { Task { await q.close() } }
        tabs.remove(at: index)
        if selectedTabID == tabID {
            selectedTabID = tabs.indices.contains(index) ? tabs[index].id : tabs.last?.id
        }
    }

    /// Closes every tab matching `predicate`.
    func closeTabs(where predicate: (WorkspaceTab) -> Bool) {
        for tab in tabs where predicate(tab) { close(tabID: tab.id) }
    }

    func closeSelectedTab() {
        if let selectedTabID { close(tabID: selectedTabID) }
    }

    var selectedTab: WorkspaceTab? {
        tabs.first { $0.id == selectedTabID }
    }

    var activeTableData: TableDataModel? {
        if case .relation(let m) = selectedTab, m.mode == .data { return m.data }
        return nil
    }

    var activeQuery: QueryEditorModel? {
        if case .query(let q) = selectedTab { return q }
        return nil
    }

    // MARK: Commands

    func refreshActive() {
        Task {
            switch selectedTab {
            case .relation(let m): await m.load()
            case .bucket(let m): await m.load()
            default: break
            }
            async let catalog: Void = reloadCatalog()
            async let project: Void? = supabase?.load()
            _ = await (catalog, project)
        }
    }

    func saveActiveTab() {
        guard let data = activeTableData else { return }
        Task { await data.save() }
    }

    func recordHistory(sql: String, duration: Duration, succeeded: Bool) {
        guard let modelContext else { return }
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        modelContext.insert(QueryHistoryItem(connectionID: connectionID, sql: sql, durationSeconds: seconds, succeeded: succeeded))
        try? modelContext.save()
    }
}

/// A relation opened in a tab: data grid + structure.
@Observable
final class RelationTabModel {
    enum Mode: String, CaseIterable, Identifiable {
        case data = "Data"
        case structure = "Structure"
        var id: String { rawValue }
    }

    let id = UUID()
    let relation: RelationInfo
    let session: DatabaseSession
    weak var owner: DatabaseModel?
    var mode: Mode = .data
    private(set) var structure: TableStructure?
    private(set) var data: TableDataModel?
    private(set) var error: String?
    private(set) var isLoading = false

    init(relation: RelationInfo, session: DatabaseSession, owner: DatabaseModel) {
        self.relation = relation
        self.session = session
        self.owner = owner
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let structure = try await session.structure(of: relation)
            self.structure = structure
            if let data {
                data.structure = structure
            } else {
                data = TableDataModel(structure: structure, session: session, owner: owner)
            }
            error = nil
            await data?.reload()
        } catch {
            self.error = error.fullDescription
        }
    }
}
