import Foundation

/// Exports result sets to CSV (RFC 4180) or JSON.
public enum ResultExporter {
    public enum Format: String, Sendable, CaseIterable, Identifiable {
        case csv, json
        public var id: String { rawValue }
        public var fileExtension: String { rawValue }
    }

    public static func export(_ result: ResultSet, as format: Format) -> String {
        switch format {
        case .csv: csv(result)
        case .json: json(result)
        }
    }

    public static func csv(_ result: ResultSet) -> String {
        func field(_ s: String) -> String {
            if s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) {
                return "\"" + s.replacing("\"", with: "\"\"") + "\""
            }
            return s
        }
        var lines = [result.columns.map { field($0.name) }.joined(separator: ",")]
        for row in result.rows {
            lines.append(result.columns.indices.map { i in
                switch row[i] {
                case .null, .default: ""
                case .text(let s): field(s)
                }
            }.joined(separator: ","))
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    public static func json(_ result: ResultSet) -> String {
        func string(_ s: String) -> String {
            var out = "\""
            for scalar in s.unicodeScalars {
                switch scalar {
                case "\"": out += "\\\""
                case "\\": out += "\\\\"
                case "\n": out += "\\n"
                case "\r": out += "\\r"
                case "\t": out += "\\t"
                case _ where scalar.value < 0x20: out += String(format: "\\u%04x", scalar.value)
                default: out.unicodeScalars.append(scalar)
                }
            }
            return out + "\""
        }
        let objects = result.rows.map { row in
            "  {" + result.columns.map { c in
                let value: String = switch row[c.index] {
                case .null, .default: "null"
                case .text(let s): string(s)
                }
                return string(c.name) + ": " + value
            }.joined(separator: ", ") + "}"
        }
        return objects.isEmpty ? "[]\n" : "[\n" + objects.joined(separator: ",\n") + "\n]\n"
    }
}
