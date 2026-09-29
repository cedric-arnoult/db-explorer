import DBCore
import SwiftUI

struct AppCommands: Commands {
    let appState: AppState
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(DatabaseModel.self) private var database

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Connection…") {
                openWindow(id: WindowID.connections)
                appState.newConnectionRequests += 1
            }
            .keyboardShortcut("n")

            Button("New Query") { database?.newQuery() }
                .keyboardShortcut("t")
                .disabled(database?.isConnected != true)
        }

        // `.saveItem` is omitted from the File menu of non-document apps, so add after `.newItem`.
        CommandGroup(after: .newItem) {
            Divider()
            Button("Save Changes") { database?.saveActiveTab() }
                .keyboardShortcut("s")
                .disabled(database?.activeTableData?.changes.isEmpty ?? true)
            Button("Discard Changes") { database?.activeTableData?.discard() }
                .keyboardShortcut("s", modifiers: [.command, .option])
                .disabled(database?.activeTableData?.changes.isEmpty ?? true)
        }

        CommandMenu("Database") {
            Button("Refresh") { database?.refreshActive() }
                .keyboardShortcut("r")
                .disabled(database?.isConnected != true)
            Divider()
            Button("Run") { database?.activeQuery?.run(scope: .selectionOrCurrent) }
                .keyboardShortcut(.return)
                .disabled(database?.activeQuery == nil || database?.activeQuery?.isRunning == true)
            Button("Run All") { database?.activeQuery?.run(scope: .all) }
                .keyboardShortcut(.return, modifiers: [.command, .shift])
                .disabled(database?.activeQuery == nil || database?.activeQuery?.isRunning == true)
            Button("Cancel Query") { database?.activeQuery?.cancel() }
                .keyboardShortcut(".")
                .disabled(database?.activeQuery?.isRunning != true)
            Divider()
            Button("Add Row") { database?.activeTableData?.addRow() }
                .keyboardShortcut("n", modifiers: [.command, .option])
                .disabled(database?.activeTableData?.isEditable != true)
            Button("Delete Selected Rows") { database?.activeTableData?.deleteSelected() }
                .keyboardShortcut(.delete)
                .disabled(database?.activeTableData?.selection.isEmpty ?? true)
            Divider()
            Button("Close Tab") { database?.closeSelectedTab() }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .disabled(database?.selectedTabID == nil)
        }

        CommandGroup(after: .windowList) {
            Button("Connections") { openWindow(id: WindowID.connections) }
                .keyboardShortcut("0")
        }
    }
}
