import DBCore
import SwiftData
import SwiftUI

/// Window for one saved connection: loads it, connects, and hosts the workspace.
struct DatabaseWindow: View {
    let connectionID: UUID
    @Environment(\.modelContext) private var modelContext
    @State private var model: DatabaseModel?
    @State private var missing = false

    var body: some View {
        Group {
            if let model {
                DatabaseWorkspace(model: model)
            } else if missing {
                ContentUnavailableView("Connection Not Found", systemImage: "questionmark.circle",
                                       description: Text("It may have been deleted."))
            } else {
                ProgressView()
            }
        }
        .task(id: connectionID) { await load() }
    }

    private func load() async {
        guard model == nil else { return }
        let id = connectionID
        guard let saved = try? modelContext.fetch(FetchDescriptor<SavedConnection>(predicate: #Predicate { $0.id == id })).first else {
            missing = true
            return
        }
        let secrets = ConnectionSecrets(
            password: Keychain.password(for: id),
            sshPassword: Keychain.password(for: id, kind: .ssh),
            supabaseAccessToken: Keychain.password(for: id, kind: .supabaseToken))
        var config = saved.config
        if config.name.isEmpty { config.name = saved.displayName }
        let model = DatabaseModel(connectionID: id, config: config, secrets: secrets)
        model.modelContext = modelContext
        self.model = model
        await model.connect()
    }
}

private struct DatabaseWorkspace: View {
    @Bindable var model: DatabaseModel
    @Environment(\.undoManager) private var undoManager
    @State private var retryPassword = ""

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 200, ideal: 260, max: 420)
        } detail: {
            detail
        }
        .navigationTitle(model.config.name)
        .navigationSubtitle(model.config.database.isEmpty ? model.config.summary : model.config.database)
        .toolbar { toolbar }
        .focusedSceneValue(model)
        .onAppear { model.undoManager = undoManager }
        .onChange(of: undoManager) { _, new in model.undoManager = new }
        .onChange(of: model.sidebarSelection) { _, item in
            guard let item else { return }
            model.open(item)
            if item == .newQuery { model.sidebarSelection = nil }
        }
        .onDisappear { Task { await model.disconnect() } }
    }

    @ViewBuilder private var detail: some View {
        switch model.phase {
        case .idle, .connecting:
            ProgressView("Connecting to \(model.config.summary)…")
        case .failed(let error):
            connectionFailed(error)
        case .connected:
            VStack(spacing: 0) {
                if !model.tabs.isEmpty {
                    WorkspaceTabBar(model: model)
                    Divider()
                }
                if let tab = model.selectedTab {
                    switch tab {
                    case .relation(let relation): RelationTabView(model: relation)
                    case .query(let query): QueryEditorView(model: query, database: model)
                    case .bucket(let bucket): BucketBrowserView(model: bucket)
                    case .edgeFunction(let tab): EdgeFunctionView(function: tab.function)
                    }
                } else {
                    ContentUnavailableView {
                        Label("Nothing Open", systemImage: "tablecells")
                    } description: {
                        Text("Select a table in the sidebar, or open a new query with ⌘T.")
                    } actions: {
                        Button("New Query") { model.newQuery() }.buttonStyle(.glassProminent)
                    }
                }
            }
        }
    }

    private func connectionFailed(_ error: DatabaseError) -> some View {
        ContentUnavailableView {
            Label("Connection Failed", systemImage: "bolt.horizontal.circle")
        } description: {
            Text(error.fullDescription).textSelection(.enabled)
        } actions: {
            VStack {
                if !model.isSupabase {
                    SecureField("Password", text: $retryPassword)
                        .frame(width: 240)
                        .onSubmit { retry() }
                }
                Button("Retry") { retry() }.buttonStyle(.glassProminent)
            }
        }
    }

    private func retry() {
        let password = retryPassword.nilIfEmpty
        Task { await model.connect(password: password) }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            ConnectionKindIcon(config: model.config)
                .imageScale(.large)
                .allowsHitTesting(false)
        }
        .sharedBackgroundVisibility(.hidden)
        ToolbarItem(placement: .primaryAction) {
            Button("Refresh", systemImage: "arrow.clockwise") { model.refreshActive() }
                .disabled(!model.isConnected)
                .help("Refresh (⌘R)")
        }
        ToolbarItem(placement: .primaryAction) {
            Button("New Query", systemImage: "square.and.pencil") { model.newQuery() }
                .disabled(!model.isConnected)
                .help("New Query (⌘T)")
        }
        if let data = model.activeTableData {
            TableDataToolbar(data: data)
        }
    }
}

/// Horizontal strip of open tabs.
struct WorkspaceTabBar: View {
    @Bindable var model: DatabaseModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassEffectContainer(spacing: 6) {
                HStack(spacing: 6) {
                    ForEach(model.tabs) { tab in
                        TabChip(tab: tab, isSelected: tab.id == model.selectedTabID,
                                select: { model.selectedTabID = tab.id },
                                close: { model.close(tabID: tab.id) })
                            .contextMenu {
                                Button("Close Tab") { model.close(tabID: tab.id) }
                                Button("Close Other Tabs") { model.closeTabs { $0.id != tab.id } }
                                    .disabled(model.tabs.count < 2)
                                Button("Close All Tabs") { model.closeTabs { _ in true } }
                            }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
        }
    }
}

private struct TabChip: View {
    let tab: WorkspaceTab
    let isSelected: Bool
    let select: () -> Void
    let close: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: tab.systemImage).imageScale(.small)
            Text(tab.title).lineLimit(1)
            if tab.hasUnsavedChanges {
                Circle().fill(.orange).frame(width: 6, height: 6).help("Unsaved changes")
            }
            Button(action: close) {
                Image(systemName: "xmark").imageScale(.small)
            }
            .buttonStyle(.plain)
            .opacity(isHovering || isSelected ? 1 : 0)
            .help("Close Tab")
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .glassEffect(isSelected ? .regular.tint(.accentColor.opacity(0.35)).interactive() : .regular.interactive(), in: .capsule)
        .contentShape(.capsule)
        .onTapGesture(perform: select)
        .onHover { isHovering = $0 }
    }
}
