import DBCore
import SwiftData
import SwiftUI

struct QueryEditorView: View {
    @Bindable var model: QueryEditorModel
    let database: DatabaseModel
    @State private var resultTab: ResultTab = .results
    @State private var showHistory = false

    enum ResultTab: String, CaseIterable, Identifiable {
        case results = "Results"
        case messages = "Messages"
        var id: String { rawValue }
    }

    var body: some View {
        VSplitView {
            VStack(spacing: 0) {
                editorToolbar
                Divider()
                TextEditor(text: $model.text, selection: $model.selection)
                    .font(.body.monospaced())
                    .autocorrectionDisabled()
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .onChange(of: model.text) { model.highlight() }
            }
            .frame(minHeight: 140, idealHeight: 280)

            VStack(spacing: 0) {
                HStack {
                    Picker("Output", selection: $resultTab) {
                        ForEach(ResultTab.allCases) { tab in
                            Text(tab == .messages && model.log.contains(where: \.isError) ? "Messages ⚠︎" : tab.rawValue).tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    Spacer()
                    if let result = model.resultSet {
                        Text("\(result.rows.count.formatted()) row\(result.rows.count == 1 ? "" : "s")")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    ExportMenu(resultSet: { model.resultSet }, filename: model.title)
                        .disabled(model.resultSet == nil)
                        .fixedSize()
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
                Divider()
                switch resultTab {
                case .results:
                    if let result = model.resultSet {
                        ResultGridView(resultSet: result)
                    } else {
                        ContentUnavailableView("Run a Query", systemImage: "play",
                                               description: Text("⌘↩ runs the selection or the statement under the cursor. ⇧⌘↩ runs everything."))
                    }
                case .messages:
                    MessagesView(log: model.log, clear: model.clearLog)
                }
            }
            .frame(minHeight: 160)
        }
        .onChange(of: model.log.count) {
            if model.log.last?.isError == true { resultTab = .messages }
            else if model.resultSet != nil { resultTab = .results }
        }
    }

    private var editorToolbar: some View {
        HStack(spacing: 8) {
            if model.isRunning {
                Button("Cancel", systemImage: "stop.fill") { model.cancel() }
                    .buttonStyle(.glass)
                    .tint(.red)
                    .help("Cancel (⌘.)")
                ProgressView().controlSize(.small)
            } else {
                Button("Run", systemImage: "play.fill") { model.run(scope: .selectionOrCurrent) }
                    .buttonStyle(.glassProminent)
                    .help("Run selection or current statement (⌘↩)")
                Button("Run All", systemImage: "forward.fill") { model.run(scope: .all) }
                    .buttonStyle(.glass)
                    .help("Run all statements (⇧⌘↩)")
            }
            Spacer()
            if let offset = model.errorOffset {
                Text("Error at character \(offset + 1)")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Button("History", systemImage: "clock.arrow.circlepath") { showHistory.toggle() }
                .buttonStyle(.glass)
                .popover(isPresented: $showHistory, arrowEdge: .bottom) {
                    QueryHistoryView(connectionID: database.connectionID) { sql in
                        model.replaceText(with: sql)
                        showHistory = false
                    }
                    .frame(width: 520, height: 400)
                }
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
    }
}

private struct MessagesView: View {
    let log: [QueryLogEntry]
    let clear: () -> Void

    var body: some View {
        if log.isEmpty {
            ContentUnavailableView("No Messages", systemImage: "text.bubble")
        } else {
            List {
                ForEach(log.reversed()) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Image(systemName: entry.isError ? "xmark.octagon.fill" : "checkmark.circle.fill")
                                .foregroundStyle(entry.isError ? .red : .green)
                            Text(entry.summary)
                                .foregroundStyle(entry.isError ? .red : .primary)
                                .textSelection(.enabled)
                            Spacer()
                            Text(entry.duration.formatted(.units(allowed: [.seconds, .milliseconds], width: .narrow)))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                            Text(entry.date, format: .dateTime.hour().minute().second())
                                .foregroundStyle(.tertiary)
                        }
                        Text(entry.statement)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 2)
                }
            }
            .contextMenu { Button("Clear Messages", action: clear) }
        }
    }
}

/// Previously executed statements for a connection.
struct QueryHistoryView: View {
    let connectionID: UUID
    let pick: (String) -> Void
    @Query private var items: [QueryHistoryItem]
    @Environment(\.modelContext) private var modelContext
    @State private var search = ""

    init(connectionID: UUID, pick: @escaping (String) -> Void) {
        self.connectionID = connectionID
        self.pick = pick
        var descriptor = FetchDescriptor<QueryHistoryItem>(
            predicate: #Predicate { $0.connectionID == connectionID },
            sortBy: [SortDescriptor(\.executedAt, order: .reverse)])
        descriptor.fetchLimit = 500
        _items = Query(descriptor)
    }

    private var filtered: [QueryHistoryItem] {
        search.isEmpty ? items : items.filter { $0.sql.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Search history", text: $search).textFieldStyle(.roundedBorder)
                Button("Clear All", role: .destructive) {
                    for item in items { modelContext.delete(item) }
                    try? modelContext.save()
                }
                .disabled(items.isEmpty)
            }
            .padding(10)
            if filtered.isEmpty {
                ContentUnavailableView("No History", systemImage: "clock")
            } else {
                List(filtered) { item in
                    Button { pick(item.sql) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.sql).font(.callout.monospaced()).lineLimit(3)
                            HStack {
                                Image(systemName: item.succeeded ? "checkmark.circle" : "xmark.circle")
                                    .foregroundStyle(item.succeeded ? .green : .red)
                                Text(item.executedAt, format: .relative(presentation: .named))
                                Text(String(format: "%.0f ms", item.durationSeconds * 1000))
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
