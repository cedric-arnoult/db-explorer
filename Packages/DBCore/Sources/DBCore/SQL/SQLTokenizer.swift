/// Minimal SQL tokenizer used for syntax highlighting.
public enum SQLTokenizer {
    public enum Kind: Sendable, Hashable {
        case keyword, string, quotedIdentifier, comment, number, parameter
    }

    public struct Token: Sendable, Hashable {
        public var kind: Kind
        /// Range in unicode scalar offsets.
        public var offsets: Range<Int>

        public func substring(of sql: String) -> Substring {
            let scalars = sql.unicodeScalars
            let lower = scalars.index(scalars.startIndex, offsetBy: offsets.lowerBound)
            let upper = scalars.index(lower, offsetBy: offsets.count)
            return sql[lower..<upper]
        }
    }

    public static let keywords: Set<String> = [
        "select", "from", "where", "and", "or", "not", "in", "is", "null", "true", "false", "as", "on", "join",
        "left", "right", "inner", "outer", "full", "cross", "natural", "using", "group", "by", "order", "having",
        "limit", "offset", "union", "all", "distinct", "except", "intersect", "insert", "into", "values", "update",
        "set", "delete", "returning", "create", "table", "view", "index", "unique", "primary", "key", "foreign",
        "references", "constraint", "check", "default", "alter", "add", "drop", "column", "rename", "to", "if",
        "exists", "cascade", "restrict", "begin", "commit", "rollback", "transaction", "savepoint", "with",
        "recursive", "case", "when", "then", "else", "end", "cast", "like", "ilike", "between", "asc", "desc",
        "nulls", "first", "last", "schema", "database", "grant", "revoke", "function", "returns", "language",
        "trigger", "sequence", "materialized", "refresh", "explain", "analyze", "vacuum", "truncate", "lateral",
        "over", "partition", "window", "filter", "any", "some", "array", "do", "nothing", "conflict", "type",
        "extension", "temporary", "temp", "only", "for", "each", "row", "execute", "procedure", "declare", "copy",
    ]

    public static func tokenize(_ sql: String) -> [Token] {
        let s = Array(sql.unicodeScalars)
        var tokens: [Token] = []
        var i = 0

        func at(_ j: Int) -> Unicode.Scalar? { j < s.count ? s[j] : nil }
        func isDigit(_ c: Unicode.Scalar?) -> Bool { c.map { ("0"..."9").contains($0) } ?? false }
        func isIdentStart(_ c: Unicode.Scalar) -> Bool { c.properties.isAlphabetic || c == "_" }
        func isIdentChar(_ c: Unicode.Scalar) -> Bool { isIdentStart(c) || isDigit(c) || c == "$" }
        func skipQuoted(_ quote: Unicode.Scalar, backslashEscapes: Bool = false) {
            i += 1
            while i < s.count {
                if backslashEscapes, s[i] == "\\" { i += 2; continue }
                if s[i] == quote {
                    if at(i + 1) == quote { i += 2; continue }
                    i += 1
                    return
                }
                i += 1
            }
            i = min(i, s.count)
        }

        while i < s.count {
            let start = i
            let c = s[i]
            if c == "-", at(i + 1) == "-" {
                while i < s.count, s[i] != "\n" { i += 1 }
                tokens.append(Token(kind: .comment, offsets: start..<i))
            } else if c == "/", at(i + 1) == "*" {
                i += 2
                var depth = 1
                while i < s.count, depth > 0 {
                    if s[i] == "*", at(i + 1) == "/" { depth -= 1; i += 2 }
                    else if s[i] == "/", at(i + 1) == "*" { depth += 1; i += 2 }
                    else { i += 1 }
                }
                i = min(i, s.count)
                tokens.append(Token(kind: .comment, offsets: start..<i))
            } else if c == "'" {
                skipQuoted("'")
                tokens.append(Token(kind: .string, offsets: start..<i))
            } else if c == "\"" {
                skipQuoted("\"")
                tokens.append(Token(kind: .quotedIdentifier, offsets: start..<i))
            } else if c == "$", isDigit(at(i + 1)) {
                i += 1
                while isDigit(at(i)) { i += 1 }
                tokens.append(Token(kind: .parameter, offsets: start..<i))
            } else if c == "$" {
                var j = i + 1
                while j < s.count, s[j] != "$", isIdentChar(s[j]) { j += 1 }
                if j < s.count, s[j] == "$" {
                    let tag = Array(s[i...j])
                    i = j + 1
                    while i < s.count {
                        if s[i] == "$", i + tag.count <= s.count, Array(s[i..<(i + tag.count)]) == tag {
                            i += tag.count
                            break
                        }
                        i += 1
                    }
                    i = min(i, s.count)
                    tokens.append(Token(kind: .string, offsets: start..<i))
                } else {
                    i += 1
                }
            } else if isDigit(c) {
                while i < s.count, isDigit(s[i]) || s[i] == "." || s[i] == "e" || s[i] == "E" { i += 1 }
                tokens.append(Token(kind: .number, offsets: start..<i))
            } else if isIdentStart(c) {
                if (c == "E" || c == "e"), at(i + 1) == "'" {
                    i += 1
                    skipQuoted("'", backslashEscapes: true)
                    tokens.append(Token(kind: .string, offsets: start..<i))
                    continue
                }
                while i < s.count, isIdentChar(s[i]) { i += 1 }
                var word = ""
                word.unicodeScalars.append(contentsOf: s[start..<i])
                if keywords.contains(word.lowercased()) {
                    tokens.append(Token(kind: .keyword, offsets: start..<i))
                }
            } else {
                i += 1
            }
        }
        return tokens
    }
}
