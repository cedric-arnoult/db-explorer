import Foundation
import DBCore
import SwiftUI

/// One line of the messages log.
struct QueryLogEntry: Identifiable {
    let id = UUID()
    let statement: String
    let outcome: Outcome
    let duration: Duration
    let date = Date.now

    enum Outcome {
        case success(command: String, rowCount: Int?, truncated: Bool)
        case failure(DatabaseError)
    }

    var summary: String {
        switch outcome {
        case .success(let command, let rowCount, let truncated):
            var s = command
            if let rowCount { s += " — \(rowCount.formatted()) row\(rowCount == 1 ? "" : "s")" }
            if truncated { s += " (showing first \(QueryConnection.rowLimit.formatted()))" }
            return s
        case .failure(let error):
            return error.fullDescription
        }
    }

    var isError: Bool {
        if case .failure = outcome { return true }
        return false
    }
}

/// A SQL editor tab. Keeps one dedicated connection so transactions span executions.
@Observable
final class QueryEditorModel {
    enum Scope {
        case all
        /// The selection if any, otherwise the statement under the cursor.
        case selectionOrCurrent
    }

    let id = UUID()
    var title: String
    var text: AttributedString
    var selection = AttributedTextSelection()
    private(set) var log: [QueryLogEntry] = []
    private(set) var resultSet: ResultSet?
    private(set) var isRunning = false
    /// Error position (character offset in the editor) to highlight.
    private(set) var errorOffset: Int?

    private let session: DatabaseSession
    private weak var owner: DatabaseModel?
    private var connection: QueryConnection?
    private var runTask: Task<Void, Never>?
    private var highlightedSource = ""

    init(title: String, text: String, session: DatabaseSession, owner: DatabaseModel) {
        self.title = title
        self.text = AttributedString(text)
        self.session = session
        self.owner = owner
        highlight()
    }

    var sql: String { String(text.characters) }

    /// Re-applies syntax colors when the text changed.
    func highlight() {
        let source = sql
        guard source != highlightedSource else { return }
        highlightedSource = source
        SQLHighlighter.apply(to: &text)
    }

    // MARK: Running

    func run(scope: Scope) {
        guard !isRunning else { return }
        let statements = statementsToRun(scope: scope)
        guard !statements.isEmpty else { return }
        isRunning = true
        errorOffset = nil
        runTask = Task { await execute(statements) }
    }

    func cancel() {
        guard isRunning else { return }
        runTask?.cancel()
        if let pid = connection?.backendPID {
            let session = self.session
            Task { try? await session.cancelBackend(pid: pid) }
        }
    }

    func close() async {
        runTask?.cancel()
        await connection?.close()
        connection = nil
    }

    func clearLog() {
        log = []
    }

    private struct PendingStatement {
        let text: String
        /// Character offset of the statement in the editor, for error positions.
        let offset: Int
    }

    private func statementsToRun(scope: Scope) -> [PendingStatement] {
        let source = sql
        func offset(_ index: String.Index) -> Int { source.distance(from: source.startIndex, to: index) }

        if scope == .selectionOrCurrent {
            switch selection.indices(in: text) {
            case .ranges(let ranges) where !ranges.isEmpty:
                guard let range = ranges.ranges.first, !range.isEmpty else { break }
                let start = text.characters.distance(from: text.startIndex, to: range.lowerBound)
                let selected = String(text[range].characters)
                return SQLStatementSplitter.split(selected).map {
                    PendingStatement(text: $0.text, offset: start + selected.distance(from: selected.startIndex, to: $0.range.lowerBound))
                }
            case .insertionPoint(let point):
                let characterOffset = text.characters.distance(from: text.startIndex, to: point)
                let cursor = source.index(source.startIndex, offsetBy: min(characterOffset, source.count))
                if let statement = SQLStatementSplitter.statement(in: source, at: cursor) {
                    return [PendingStatement(text: statement.text, offset: offset(statement.range.lowerBound))]
                }
                return []
            default:
                break
            }
        }
        return SQLStatementSplitter.split(source).map { PendingStatement(text: $0.text, offset: offset($0.range.lowerBound)) }
    }

    private func execute(_ statements: [PendingStatement]) async {
        defer {
            isRunning = false
            runTask = nil
        }
        do {
            if connection?.isClosed ?? true {
                connection = try await session.makeQueryConnection()
            }
        } catch {
            log.append(QueryLogEntry(statement: statements.first?.text ?? "", outcome: .failure(error), duration: .zero))
            return
        }
        guard let connection else { return }

        for statement in statements {
            if Task.isCancelled { break }
            let start = ContinuousClock.now
            do {
                let result = try await connection.execute(statement.text)
                log.append(QueryLogEntry(
                    statement: statement.text,
                    outcome: .success(command: result.command, rowCount: result.rowCount, truncated: result.isTruncated),
                    duration: result.duration))
                if !result.resultSet.columns.isEmpty || result.command == "SELECT" {
                    resultSet = result.resultSet
                }
                owner?.recordHistory(sql: statement.text, duration: result.duration, succeeded: true)
            } catch {
                let duration = ContinuousClock.now - start
                log.append(QueryLogEntry(statement: statement.text, outcome: .failure(error), duration: duration))
                owner?.recordHistory(sql: statement.text, duration: duration, succeeded: false)
                if let position = error.position { errorOffset = statement.offset + position - 1 }
                break
            }
        }
    }

    /// Inserts text (e.g. from history) replacing the editor contents.
    func replaceText(with sql: String) {
        text = AttributedString(sql)
        highlightedSource = ""
        highlight()
    }
}

/// Colors SQL tokens in place, without touching the characters (so the selection stays valid).
enum SQLHighlighter {
    static func apply(to text: inout AttributedString) {
        let source = String(text.characters)
        text.foregroundColor = nil
        let tokens = SQLTokenizer.tokenize(source)
        guard !tokens.isEmpty else { return }
        var indices = Array(text.unicodeScalars.indices)
        indices.append(text.endIndex)
        for token in tokens where token.offsets.upperBound < indices.count {
            let range = indices[token.offsets.lowerBound]..<indices[token.offsets.upperBound]
            text[range].foregroundColor = color(for: token.kind)
        }
    }

    static func color(for kind: SQLTokenizer.Kind) -> Color {
        switch kind {
        case .keyword: .pink
        case .string: .orange
        case .quotedIdentifier: .teal
        case .comment: .secondary
        case .number: .blue
        case .parameter: .purple
        }
    }
}
