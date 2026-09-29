/// A single value in a result grid or pending edit.
public enum CellValue: Sendable, Hashable, Codable {
    case null
    case text(String)
    /// Use the column default (only meaningful for new rows).
    case `default`

    public var isNull: Bool { self == .null }

    /// Text shown in the grid.
    public var displayString: String {
        switch self {
        case .null: "NULL"
        case .text(let s): s
        case .default: "DEFAULT"
        }
    }

    public var text: String? {
        if case .text(let s) = self { s } else { nil }
    }
}
