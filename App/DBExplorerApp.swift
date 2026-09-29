import SwiftData
import SwiftUI

enum WindowID {
    static let connections = "connections"
    static let database = "database"
}

/// App-wide UI state shared between scenes and menu commands.
@Observable
final class AppState {
    /// Incremented to ask the connections window to open the "new connection" editor.
    var newConnectionRequests = 0
}

@main
struct DBExplorerApp: App {
    @State private var appState = AppState()
    private let modelContainer = PersistenceController.container

    var body: some Scene {
        Window("Connections", id: WindowID.connections) {
            ConnectionListView()
        }
        .environment(appState)
        .modelContainer(modelContainer)
        .defaultSize(width: 760, height: 520)
        .commands { AppCommands(appState: appState) }

        WindowGroup("Database", id: WindowID.database, for: UUID.self) { $connectionID in
            if let connectionID {
                DatabaseWindow(connectionID: connectionID)
            } else {
                ContentUnavailableView("No Connection", systemImage: "cylinder.split.1x2")
            }
        }
        .environment(appState)
        .modelContainer(modelContainer)
        .defaultSize(width: 1280, height: 820)
    }
}

enum PersistenceController {
    /// Per-user store: `~/Library/Application Support/<bundle id>/DBExplorer.store`. Nothing ships in the app bundle.
    static let storeURL: URL = {
        let folder = URL.applicationSupportDirectory.appending(path: Bundle.main.bundleIdentifier ?? "dev.dbexplorer.DBExplorer")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appending(path: "DBExplorer.store")
    }()

    static let container: ModelContainer = {
        do {
            return try ModelContainer(
                for: SavedConnection.self, QueryHistoryItem.self,
                configurations: ModelConfiguration(url: storeURL))
        } catch {
            fatalError("Could not open the DB Explorer store: \(error)")
        }
    }()
}
