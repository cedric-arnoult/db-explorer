import DBCore
import SwiftUI

/// Renders a cell value; NULL and DEFAULT are shown as dimmed placeholders.
struct CellText: View {
    let value: CellValue

    var body: some View {
        switch value {
        case .null:
            Text("NULL").italic().foregroundStyle(.tertiary)
        case .default:
            Text("DEFAULT").italic().foregroundStyle(.secondary)
        case .text(let s):
            // Keep the grid single-line; the inspector shows the full value.
            Text(s.count > 500 ? String(s.prefix(500)) + "…" : s.replacing("\n", with: "⏎"))
                .lineLimit(1)
        }
    }
}

/// Sort requested by a grid column header. Sorting happens on the server, so comparison is a no-op.
nonisolated struct ColumnSort<Row>: SortComparator, Hashable {
    let column: Int
    var order: SortOrder = .forward

    func compare(_ lhs: Row, _ rhs: Row) -> ComparisonResult { .orderedSame }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.column == rhs.column && lhs.order == rhs.order }
    func hash(into hasher: inout Hasher) {
        hasher.combine(column)
        hasher.combine(order)
    }
}

extension ResultColumn {
    /// Human-readable type name for common OIDs.
    var typeName: String {
        switch typeOID {
        case CellDecoder.OID.bool: "bool"
        case CellDecoder.OID.int2: "int2"
        case CellDecoder.OID.int4: "int4"
        case CellDecoder.OID.int8: "int8"
        case CellDecoder.OID.text: "text"
        case CellDecoder.OID.varchar: "varchar"
        case CellDecoder.OID.bpchar: "char"
        case CellDecoder.OID.numeric: "numeric"
        case CellDecoder.OID.float4: "float4"
        case CellDecoder.OID.float8: "float8"
        case CellDecoder.OID.uuid: "uuid"
        case CellDecoder.OID.json: "json"
        case CellDecoder.OID.jsonb: "jsonb"
        case CellDecoder.OID.date: "date"
        case CellDecoder.OID.timestamp: "timestamp"
        case CellDecoder.OID.timestamptz: "timestamptz"
        case CellDecoder.OID.bytea: "bytea"
        default: "oid \(typeOID)"
        }
    }
}
