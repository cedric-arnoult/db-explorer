/// A single SQL statement found in a script.
public struct SQLStatement: Sendable, Hashable {
    /// Statement text, trimmed, without the trailing `;`.
    public var text: String
    /// Range of the statement in the original script (trimmed, without the `;`).
    public var range: Range<String.Index>
}

/// Splits a SQL script into statements on `;`, respecting single-quoted strings
/// (including `E''` escapes), quoted identifiers, dollar quoting and comments.
public enum SQLStatementSplitter {
    public static func split(_ sql: String) -> [SQLStatement] {
        var statements: [SQLStatement] = []
        let chars = Array(sql.unicodeScalars)
        let indices = Array(sql.unicodeScalars.indices) + [sql.endIndex]
        var i = 0
        var hasContent = false
        var contentStart: Int?
        var contentEnd = 0

        func markContent(_ from: Int, _ to: Int) {
            if contentStart == nil { contentStart = from }
            contentEnd = to
            hasContent = true
        }

        func flush() {
            if hasContent, let s = contentStart {
                let range = indices[s]..<indices[contentEnd]
                statements.append(SQLStatement(text: String(sql[range]), range: range))
            }
            hasContent = false
            contentStart = nil
        }

        while i < chars.count {
            let c = chars[i]
            let next: Unicode.Scalar? = i + 1 < chars.count ? chars[i + 1] : nil
            switch c {
            case "-" where next == "-":
                // Line comment: skip to end of line. Comments inside a statement are kept.
                let from = i
                while i < chars.count, chars[i] != "\n" { i += 1 }
                if hasContent { markContent(from, i) }
                continue
            case "/" where next == "*":
                let from = i
                var depth = 1
                i += 2
                while i < chars.count, depth > 0 {
                    if chars[i] == "/", i + 1 < chars.count, chars[i + 1] == "*" { depth += 1; i += 2 }
                    else if chars[i] == "*", i + 1 < chars.count, chars[i + 1] == "/" { depth -= 1; i += 2 }
                    else { i += 1 }
                }
                if hasContent { markContent(from, i) }
                continue
            case "'":
                let from = i
                let isEscapeString = i > 0 && (chars[i - 1] == "E" || chars[i - 1] == "e")
                    && (i < 2 || !isIdentifierChar(chars[i - 2]))
                i += 1
                while i < chars.count {
                    if isEscapeString, chars[i] == "\\" { i += 2; continue }
                    if chars[i] == "'" {
                        if i + 1 < chars.count, chars[i + 1] == "'" { i += 2; continue }
                        i += 1
                        break
                    }
                    i += 1
                }
                markContent(from, min(i, chars.count))
                continue
            case "\"":
                let from = i
                i += 1
                while i < chars.count {
                    if chars[i] == "\"" {
                        if i + 1 < chars.count, chars[i + 1] == "\"" { i += 2; continue }
                        i += 1
                        break
                    }
                    i += 1
                }
                markContent(from, min(i, chars.count))
                continue
            case "$":
                if let tagEnd = dollarTagEnd(chars, at: i) {
                    let tag = Array(chars[i...tagEnd])
                    let from = i
                    i = tagEnd + 1
                    while i < chars.count {
                        if chars[i] == "$", i + tag.count <= chars.count, Array(chars[i..<(i + tag.count)]) == tag {
                            i += tag.count
                            break
                        }
                        i += 1
                    }
                    markContent(from, min(i, chars.count))
                    continue
                }
                markContent(i, i + 1)
            case ";":
                flush()
            default:
                if !c.properties.isWhitespace { markContent(i, i + 1) }
            }
            i += 1
        }
        flush()
        return statements
    }

    /// Returns the statement containing `index`, or the closest statement before it.
    public static func statement(in sql: String, at index: String.Index) -> SQLStatement? {
        let statements = split(sql)
        if let hit = statements.first(where: { $0.range.contains(index) || $0.range.upperBound == index }) {
            return hit
        }
        return statements.last(where: { $0.range.upperBound <= index }) ?? statements.first
    }

    private static func isIdentifierChar(_ c: Unicode.Scalar) -> Bool {
        c.properties.isAlphabetic || c == "_" || ("0"..."9").contains(c)
    }

    /// If `chars[i]` starts a dollar-quote tag (`$$` or `$tag$`), returns the index of the closing `$` of the tag.
    private static func dollarTagEnd(_ chars: [Unicode.Scalar], at i: Int) -> Int? {
        // `$1` is a parameter, and `a$b` is part of an identifier.
        if i > 0, isIdentifierChar(chars[i - 1]) { return nil }
        var j = i + 1
        while j < chars.count {
            let c = chars[j]
            if c == "$" { return j }
            let valid = c.properties.isAlphabetic || c == "_" || (j > i + 1 && ("0"..."9").contains(c))
            if !valid { return nil }
            j += 1
        }
        return nil
    }
}
