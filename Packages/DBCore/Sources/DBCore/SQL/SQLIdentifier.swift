/// Helpers to safely embed identifiers and literals in generated SQL.
public enum SQLIdentifier {
    /// Quotes an identifier: `my"table` → `"my""table"`.
    public static func quote(_ identifier: String) -> String {
        "\"" + identifier.replacing("\"", with: "\"\"") + "\""
    }

    /// Quotes a schema-qualified name: `"schema"."name"`.
    public static func qualified(schema: String, name: String) -> String {
        quote(schema) + "." + quote(name)
    }

    /// Quotes a string literal: `it's` → `'it''s'`.
    public static func literal(_ value: String) -> String {
        "'" + value.replacing("'", with: "''") + "'"
    }
}
