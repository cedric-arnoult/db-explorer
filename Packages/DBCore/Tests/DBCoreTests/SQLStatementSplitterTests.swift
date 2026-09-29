import Testing
@testable import DBCore

@Suite struct SQLStatementSplitterTests {
    func texts(_ sql: String) -> [String] { SQLStatementSplitter.split(sql).map(\.text) }

    @Test func basic() {
        #expect(texts("select 1; select 2;") == ["select 1", "select 2"])
        #expect(texts("select 1") == ["select 1"])
        #expect(texts(" ; ;\n ") == [])
    }

    @Test func quotes() {
        #expect(texts("select 'a;b'; select \"x;y\" from t") == ["select 'a;b'", "select \"x;y\" from t"])
        #expect(texts("select 'it''s; fine'; select 2") == ["select 'it''s; fine'", "select 2"])
        #expect(texts("select E'a\\';b'; select 2") == ["select E'a\\';b'", "select 2"])
    }

    @Test func dollarQuoting() {
        let fn = """
        create function f() returns int as $$ begin return 1; end; $$ language plpgsql;
        select $tag$ ; $$ ; $tag$; select $1
        """
        #expect(texts(fn) == [
            "create function f() returns int as $$ begin return 1; end; $$ language plpgsql",
            "select $tag$ ; $$ ; $tag$",
            "select $1",
        ])
    }

    @Test func comments() {
        #expect(texts("-- one; two\nselect 1; /* a; /* nested; */ b */ select 2") == ["select 1", "select 2"])
        #expect(texts("select 1 -- trailing; comment\n; select 2") == ["select 1 -- trailing; comment", "select 2"])
        #expect(texts("-- only a comment") == [])
    }

    @Test func identifiersWithDollar() {
        #expect(texts("select a$b; select 2") == ["select a$b", "select 2"])
    }

    @Test func ranges() {
        let sql = "select 1;\n  select 2 ;"
        let statements = SQLStatementSplitter.split(sql)
        #expect(statements.count == 2)
        #expect(String(sql[statements[1].range]) == "select 2")
    }

    @Test func statementAtCursor() {
        let sql = "select 1;\nselect 2;\nselect 3"
        let idx = sql.range(of: "2")!.lowerBound
        #expect(SQLStatementSplitter.statement(in: sql, at: idx)?.text == "select 2")
        #expect(SQLStatementSplitter.statement(in: sql, at: sql.endIndex)?.text == "select 3")
        // Cursor right after a `;` picks the statement before it.
        let afterFirst = sql.index(after: sql.firstIndex(of: ";")!)
        #expect(SQLStatementSplitter.statement(in: sql, at: afterFirst)?.text == "select 1")
    }
}

@Suite struct SQLIdentifierTests {
    @Test func quoting() {
        #expect(SQLIdentifier.quote("users") == "\"users\"")
        #expect(SQLIdentifier.quote("we\"ird") == "\"we\"\"ird\"")
        #expect(SQLIdentifier.qualified(schema: "public", name: "My Table") == "\"public\".\"My Table\"")
        #expect(SQLIdentifier.literal("it's") == "'it''s'")
    }
}

@Suite struct SQLTokenizerTests {
    @Test func kinds() {
        let sql = "SELECT 'a', \"b\", 42 -- c\nFROM t WHERE x = $1"
        let tokens = SQLTokenizer.tokenize(sql).map { ($0.kind, String($0.substring(of: sql))) }
        #expect(tokens.map(\.0) == [.keyword, .string, .quotedIdentifier, .number, .comment, .keyword, .keyword, .parameter])
        #expect(tokens.map(\.1) == ["SELECT", "'a'", "\"b\"", "42", "-- c", "FROM", "WHERE", "$1"])
    }

    @Test func escapeStringAndUnicode() {
        let sql = "select é, E'a\\'b' from t"
        let tokens = SQLTokenizer.tokenize(sql)
        #expect(tokens.map(\.kind) == [.keyword, .string, .keyword])
        #expect(String(tokens[1].substring(of: sql)) == "E'a\\'b'")
    }

    @Test func dollarString() {
        let sql = "select $x$ it's $x$"
        let tokens = SQLTokenizer.tokenize(sql)
        #expect(tokens.last.map { String($0.substring(of: sql)) } == "$x$ it's $x$")
    }
}
