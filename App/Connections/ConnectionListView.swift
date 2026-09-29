import DBCore
import SwiftData
import SwiftUI

struct ConnectionListView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openWindow) private var openWindow
    @Query(sort: \SavedConnection.name) private var connections: [SavedConnection]
    @State private var selection: Set<UUID> = []
    @State private var editor: EditorRequest?
    @State private var pendingDelete: SavedConnection?
    @State private var searchText = ""

    struct EditorRequest: Identifiable {
        let id = UUID()
        let model: ConnectionEditorModel
    }

    private var filtered: [SavedConnection] {
        guard !searchText.isEmpty else { return connections }
        return connections.filter {
            $0.displayName.localizedCaseInsensitiveContains(searchText)
                || $0.config.summary.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        Group {
            if connections.isEmpty {
                ContentUnavailableView {
                    Label("No Connections", systemImage: "cylinder.split.1x2")
                } description: {
                    Text("Add a PostgreSQL server to start exploring.")
                } actions: {
                    Button("New Connection…") { newConnection() }
                        .buttonStyle(.glassProminent)
                }
            } else {
                list
            }
        }
        .searchable(text: $searchText, placement: .toolbar, prompt: "Filter")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("New Connection", systemImage: "plus") { newConnection() }
            }
        }
        .sheet(item: $editor) { request in
            ConnectionEditorView(model: request.model)
        }
        .confirmationDialog(
            "Delete “\(pendingDelete?.displayName ?? "")”?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
        ) {
            Button("Delete", role: .destructive) {
                if let connection = pendingDelete { delete(connection) }
            }
        } message: {
            Text("The saved password is removed from the Keychain too.")
        }
        .onChange(of: appState.newConnectionRequests) { newConnection() }
        .navigationTitle("Connections")
    }

    private var list: some View {
        List(selection: $selection) {
            ForEach(filtered) { connection in
                ConnectionRow(connection: connection)
                    .tag(connection.id)
            }
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            if let id = ids.first, let connection = connections.first(where: { $0.id == id }) {
                Button("Connect") { open(connection) }
                Button("Edit…") { editor = EditorRequest(model: ConnectionEditorModel(connection: connection)) }
                Button("Duplicate") { editor = EditorRequest(model: ConnectionEditorModel(duplicating: connection)) }
                if connection.supabaseRef == nil {
                    Button("Copy Connection String") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(ConnectionString.format(connection.config), forType: .string)
                    }
                }
                Divider()
                Button("Delete…", role: .destructive) { pendingDelete = connection }
            }
        } primaryAction: { ids in
            for id in ids {
                if let connection = connections.first(where: { $0.id == id }) { open(connection) }
            }
        }
        .onDeleteCommand {
            if let id = selection.first { pendingDelete = connections.first { $0.id == id } }
        }
    }

    private func newConnection() {
        editor = EditorRequest(model: ConnectionEditorModel(connection: nil))
    }

    private func open(_ connection: SavedConnection) {
        connection.lastUsedAt = .now
        openWindow(id: WindowID.database, value: connection.id)
    }

    private func delete(_ connection: SavedConnection) {
        Keychain.deleteAll(for: connection.id)
        modelContext.delete(connection)
        try? modelContext.save()
        pendingDelete = nil
    }
}

private struct ConnectionRow: View {
    let connection: SavedConnection

    var body: some View {
        HStack(spacing: 10) {
            ColorDot(tag: connection.colorTag)
            ConnectionKindIcon(config: connection.config)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(connection.displayName).font(.headline)
                Text(connection.config.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if connection.sshEnabled {
                Image(systemName: "lock.shield").foregroundStyle(.secondary).help("SSH tunnel")
            }
            if let last = connection.lastUsedAt {
                Text(last, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }
}
