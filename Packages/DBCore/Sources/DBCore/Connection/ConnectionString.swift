import Foundation

/// Error raised while parsing a connection string.
public enum ConnectionStringError: Error, Sendable, Equatable, LocalizedError {
    case empty
    case invalidScheme(String)
    case invalidPort(String)
    case invalidHost(String)
    case invalidParameter(String)
    case invalidSSLMode(String)
    case invalidPercentEncoding(String)
    case unterminatedQuote

    public var errorDescription: String? {
        switch self {
        case .empty: "The connection string is empty."
        case .invalidScheme(let s): "Unsupported scheme “\(s)”. Use postgresql:// or postgres://."
        case .invalidPort(let p): "Invalid port “\(p)”."
        case .invalidHost(let h): "Invalid host “\(h)”."
        case .invalidParameter(let p): "Invalid parameter “\(p)”."
        case .invalidSSLMode(let m): "Invalid sslmode “\(m)”."
        case .invalidPercentEncoding(let s): "Invalid percent-encoding in “\(s)”."
        case .unterminatedQuote: "Unterminated quoted value."
        }
    }
}

/// Result of parsing a connection string.
public struct ParsedConnectionString: Sendable, Equatable {
    public var config: ConnectionConfig
    public var password: String?
    /// Unknown parameters, kept verbatim.
    public var unknownParameters: [(key: String, value: String)]

    public var warnings: [String] {
        unknownParameters.map { "Unsupported parameter “\($0.key)” was ignored." }
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.config == rhs.config && lhs.password == rhs.password
            && lhs.unknownParameters.map(\.key) == rhs.unknownParameters.map(\.key)
            && lhs.unknownParameters.map(\.value) == rhs.unknownParameters.map(\.value)
    }
}

/// Parses and formats libpq connection strings (URI and key/value forms).
public enum ConnectionString {
    /// Whether `text` looks like a connection string rather than a plain host name.
    public static func looksLikeConnectionString(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return t.hasPrefix("postgresql://") || t.hasPrefix("postgres://")
            || (t.contains("=") && (t.contains("host=") || t.contains("dbname=") || t.contains("user=")))
    }

    public static func parse(_ text: String) throws(ConnectionStringError) -> ParsedConnectionString {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw .empty }
        if let schemeEnd = trimmed.range(of: "://") {
            let scheme = trimmed[..<schemeEnd.lowerBound].lowercased()
            guard scheme == "postgresql" || scheme == "postgres" else { throw .invalidScheme(scheme) }
            return try parseURI(String(trimmed[schemeEnd.upperBound...]))
        }
        if trimmed.contains("=") { return try parseKeyValue(trimmed) }
        if let colon = trimmed.firstIndex(of: ":"), !trimmed.contains("://") {
            let scheme = String(trimmed[..<colon])
            if !scheme.contains(".") && !scheme.contains("[") { throw .invalidScheme(scheme) }
        }
        throw .invalidScheme("")
    }

    // MARK: URI

    private static func parseURI(_ rest: String) throws(ConnectionStringError) -> ParsedConnectionString {
        var config = ConnectionConfig(host: "", port: 5432, tlsMode: .prefer)
        var password: String?
        var unknown: [(String, String)] = []

        var remainder = Substring(rest)
        var query: Substring = ""
        if let q = remainder.firstIndex(of: "?") {
            query = remainder[remainder.index(after: q)...]
            remainder = remainder[..<q]
        }
        var authority = remainder
        var path: Substring = ""
        if let slash = remainder.firstIndex(of: "/") {
            authority = remainder[..<slash]
            path = remainder[remainder.index(after: slash)...]
        }

        if let at = authority.lastIndex(of: "@") {
            let userInfo = authority[..<at]
            authority = authority[authority.index(after: at)...]
            if let colon = userInfo.firstIndex(of: ":") {
                config.user = try decode(userInfo[..<colon])
                password = try decode(userInfo[userInfo.index(after: colon)...])
            } else {
                config.user = try decode(userInfo)
            }
        }

        // Host and port. Only the first host of a multi-host list is used.
        if let comma = authority.firstIndex(of: ",") { authority = authority[..<comma] }
        if authority.hasPrefix("[") {
            guard let close = authority.firstIndex(of: "]") else { throw .invalidHost(String(authority)) }
            config.host = String(authority[authority.index(after: authority.startIndex)..<close])
            let after = authority[authority.index(after: close)...]
            if after.hasPrefix(":") {
                config.port = try parsePort(after.dropFirst())
            } else if !after.isEmpty {
                throw .invalidHost(String(authority))
            }
        } else if let colon = authority.lastIndex(of: ":") {
            config.host = try decode(authority[..<colon])
            config.port = try parsePort(authority[authority.index(after: colon)...])
        } else {
            config.host = try decode(authority)
        }

        config.database = try decode(path)

        for pair in query.split(separator: "&", omittingEmptySubsequences: true) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = try decode(parts[0])
            let value = parts.count > 1 ? try decode(parts[1]) : ""
            if let extra = try apply(key: key, value: value, to: &config, password: &password) {
                unknown.append(extra)
            }
        }
        return ParsedConnectionString(config: config, password: password, unknownParameters: unknown)
    }

    // MARK: Key/value

    private static func parseKeyValue(_ text: String) throws(ConnectionStringError) -> ParsedConnectionString {
        var config = ConnectionConfig(host: "", port: 5432, tlsMode: .prefer)
        var password: String?
        var unknown: [(String, String)] = []
        let chars = Array(text)
        var i = 0

        func skipSpaces() { while i < chars.count, chars[i].isWhitespace { i += 1 } }

        while true {
            skipSpaces()
            guard i < chars.count else { break }
            var key = ""
            while i < chars.count, chars[i] != "=", !chars[i].isWhitespace { key.append(chars[i]); i += 1 }
            skipSpaces()
            guard i < chars.count, chars[i] == "=" else { throw .invalidParameter(key) }
            i += 1
            skipSpaces()
            var value = ""
            if i < chars.count, chars[i] == "'" {
                i += 1
                var closed = false
                while i < chars.count {
                    if chars[i] == "\\", i + 1 < chars.count { value.append(chars[i + 1]); i += 2; continue }
                    if chars[i] == "'" { closed = true; i += 1; break }
                    value.append(chars[i]); i += 1
                }
                if !closed { throw .unterminatedQuote }
            } else {
                while i < chars.count, !chars[i].isWhitespace {
                    if chars[i] == "\\", i + 1 < chars.count { value.append(chars[i + 1]); i += 2; continue }
                    value.append(chars[i]); i += 1
                }
            }
            if let extra = try apply(key: key, value: value, to: &config, password: &password) {
                unknown.append(extra)
            }
        }
        return ParsedConnectionString(config: config, password: password, unknownParameters: unknown)
    }

    // MARK: Shared

    /// Applies a known parameter to the config, or returns it as unknown.
    private static func apply(
        key: String, value: String, to config: inout ConnectionConfig, password: inout String?
    ) throws(ConnectionStringError) -> (String, String)? {
        switch key {
        case "host": config.host = value
        case "hostaddr": if config.host.isEmpty { config.host = value }
        case "port": config.port = try parsePort(Substring(value))
        case "dbname": config.database = value
        case "user": config.user = value
        case "password": password = value
        case "sslmode":
            guard let mode = TLSMode(rawValue: value) else { throw .invalidSSLMode(value) }
            config.tlsMode = mode
        case "connect_timeout":
            guard let t = Int(value), t >= 0 else { throw .invalidParameter("connect_timeout=\(value)") }
            config.connectTimeout = t
        case "application_name": config.applicationName = value
        case "sslrootcert": config.sslRootCert = value
        default: return (key, value)
        }
        return nil
    }

    private static func parsePort(_ text: Substring) throws(ConnectionStringError) -> Int {
        if text.isEmpty { return 5432 }
        guard let port = Int(text), (1...65535).contains(port) else { throw .invalidPort(String(text)) }
        return port
    }

    private static func decode(_ text: Substring) throws(ConnectionStringError) -> String {
        guard text.contains("%") else { return String(text) }
        guard let decoded = String(text).removingPercentEncoding else {
            throw .invalidPercentEncoding(String(text))
        }
        return decoded
    }

    // MARK: Formatting

    /// Formats a config as a `postgresql://` URI. The password is included only when given.
    public static func format(_ config: ConnectionConfig, password: String? = nil) -> String {
        var s = "postgresql://"
        if !config.user.isEmpty {
            s += encode(config.user)
            if let password, !password.isEmpty { s += ":" + encode(password) }
            s += "@"
        }
        var params: [(String, String)] = []
        if config.isUnixSocket {
            params.append(("host", config.host))
        } else {
            s += config.host.contains(":") ? "[\(config.host)]" : encode(config.host)
            if config.port != 5432 { s += ":\(config.port)" }
        }
        if !config.database.isEmpty { s += "/" + encode(config.database) }
        if config.tlsMode != .prefer { params.append(("sslmode", config.tlsMode.rawValue)) }
        if let t = config.connectTimeout { params.append(("connect_timeout", String(t))) }
        if let a = config.applicationName, !a.isEmpty { params.append(("application_name", a)) }
        if let c = config.sslRootCert, !c.isEmpty { params.append(("sslrootcert", c)) }
        if !params.isEmpty {
            s += "?" + params.map { encode($0.0) + "=" + encode($0.1) }.joined(separator: "&")
        }
        return s
    }

    private static let unreserved: CharacterSet = {
        var set = CharacterSet.alphanumerics.intersection(CharacterSet(charactersIn: Unicode.Scalar(0)...Unicode.Scalar(127)))
        set.insert(charactersIn: "-._~")
        return set
    }()

    private static func encode(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? text
    }
}
