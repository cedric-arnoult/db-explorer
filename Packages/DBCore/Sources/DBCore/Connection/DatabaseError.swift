import Foundation
import PostgresNIO

/// Error surfaced to the UI, with server diagnostics when available.
public struct DatabaseError: Error, Sendable, LocalizedError, Equatable {
    public enum Kind: Sendable, Equatable {
        case connection
        case server
        case timeout
        case cancelled
        case unexpectedRowCount(expected: Int, actual: Int)
        case invalidEdit
        case other
    }

    public var kind: Kind
    public var message: String
    public var detail: String?
    public var hint: String?
    public var sqlState: String?
    /// 1-based character position of the error in the statement, when reported by the server.
    public var position: Int?

    public init(kind: Kind, message: String, detail: String? = nil, hint: String? = nil,
                sqlState: String? = nil, position: Int? = nil) {
        self.kind = kind
        self.message = message
        self.detail = detail
        self.hint = hint
        self.sqlState = sqlState
        self.position = position
    }

    public var errorDescription: String? { message }

    /// Message, detail and hint on separate lines.
    public var fullDescription: String {
        var lines = [message]
        if let detail { lines.append("Detail: \(detail)") }
        if let hint { lines.append("Hint: \(hint)") }
        if let position { lines.append("Position: \(position)") }
        return lines.joined(separator: "\n")
    }

    public static let timeout = DatabaseError(kind: .timeout, message: "The connection timed out.")
    public static let cancelled = DatabaseError(kind: .cancelled, message: "The query was cancelled.")
    public static let notConnected = DatabaseError(kind: .connection, message: "Not connected.")

    /// Converts any error thrown by PostgresNIO (or elsewhere) into a `DatabaseError`.
    public init(_ error: any Error) {
        switch error {
        case let e as DatabaseError:
            self = e
        case is CancellationError:
            self = .cancelled
        case let e as PostgresTransactionError:
            if let inner = e.closureError ?? e.beginError ?? e.commitError ?? e.rollbackError {
                self.init(inner)
            } else {
                self.init(kind: .other, message: "Transaction failed.")
            }
        case let e as PSQLError:
            if let info = e.serverInfo, let message = info[.message] {
                let isCancel = info[.sqlState] == "57014"
                self.init(
                    kind: isCancel ? .cancelled : .server,
                    message: message,
                    detail: info[.detail],
                    hint: info[.hint],
                    sqlState: info[.sqlState],
                    position: info[.position].flatMap(Int.init)
                )
            } else if e.code == .queryCancelled {
                self = .cancelled
            } else {
                var message: String
                switch e.code {
                case .connectionError: message = "Could not connect to the server."
                case .serverClosedConnection: message = "The server closed the connection."
                case .clientClosedConnection, .poolClosed: message = "The connection is closed."
                case .sslUnsupported: message = "The server does not support TLS."
                case .authMechanismRequiresPassword: message = "The server requires a password."
                case .unsupportedAuthMechanism: message = "Unsupported authentication method."
                default: message = "Database error (\(e.code))."
                }
                if let underlying = e.underlying {
                    message += " " + ((underlying as? LocalizedError)?.errorDescription ?? String(describing: underlying))
                }
                self.init(kind: .connection, message: message)
            }
        case let e as LocalizedError:
            self.init(kind: .other, message: e.errorDescription ?? String(describing: e))
        default:
            self.init(kind: .other, message: String(describing: error))
        }
    }
}
