import Foundation

public struct S3Bucket: Sendable, Hashable, Identifiable {
    public var name: String
    public var creationDate: Date?
    public var id: String { name }
    public init(name: String, creationDate: Date? = nil) {
        self.name = name
        self.creationDate = creationDate
    }
}

public struct S3Object: Sendable, Hashable, Identifiable {
    public var key: String
    public var size: Int64
    public var lastModified: Date?
    public var eTag: String?
    public var storageClass: String?
    public var id: String { key }
    public init(key: String, size: Int64, lastModified: Date? = nil, eTag: String? = nil, storageClass: String? = nil) {
        self.key = key
        self.size = size
        self.lastModified = lastModified
        self.eTag = eTag
        self.storageClass = storageClass
    }
}

/// One page of `ListObjectsV2`.
public struct S3ObjectListing: Sendable, Hashable {
    public var commonPrefixes: [String]
    public var objects: [S3Object]
    public var nextContinuationToken: String?
    public init(commonPrefixes: [String] = [], objects: [S3Object] = [], nextContinuationToken: String? = nil) {
        self.commonPrefixes = commonPrefixes
        self.objects = objects
        self.nextContinuationToken = nextContinuationToken
    }
}

/// Response headers of `HeadObject`, in server order.
public struct S3ObjectHead: Sendable, Hashable {
    public var headers: [KeyValue]
    public init(headers: [KeyValue]) { self.headers = headers }

    public func value(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
    public var contentType: String? { value("Content-Type") }
    public var contentLength: Int64? { value("Content-Length").flatMap { Int64($0) } }
}

public struct KeyValue: Sendable, Hashable, Identifiable {
    public var key: String
    public var value: String
    public var id: String { key }
    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}

/// Read-only client for an S3-compatible endpoint using path-style addressing.
public struct S3Client: Sendable {
    /// Base URL, e.g. `https://<ref>.storage.supabase.co/storage/v1/s3`. Buckets are appended as path segments.
    public var endpoint: URL
    public var region: String
    public var credentials: S3Credentials
    private let urlSession: URLSession

    public init(endpoint: URL, region: String, credentials: S3Credentials, urlSession: URLSession = .shared) {
        self.endpoint = endpoint
        self.region = region
        self.credentials = credentials
        self.urlSession = urlSession
    }

    public func listBuckets() async throws(DatabaseError) -> [S3Bucket] {
        let root = try xml(try await send("GET", bucket: nil, key: nil))
        return root.all("Bucket").map {
            S3Bucket(name: $0.text("Name") ?? "", creationDate: $0.text("CreationDate").flatMap(S3Date.parse))
        }
    }

    public func listObjects(
        bucket: String, prefix: String = "", delimiter: String? = "/", continuationToken: String? = nil, maxKeys: Int = 1000
    ) async throws(DatabaseError) -> S3ObjectListing {
        var query = [("list-type", "2"), ("max-keys", String(maxKeys))]
        if !prefix.isEmpty { query.append(("prefix", prefix)) }
        if let delimiter { query.append(("delimiter", delimiter)) }
        if let continuationToken { query.append(("continuation-token", continuationToken)) }
        let root = try xml(try await send("GET", bucket: bucket, key: nil, query: query))
        return S3ObjectListing(
            commonPrefixes: root.all("CommonPrefixes").compactMap { $0.text("Prefix") },
            objects: root.all("Contents").map {
                S3Object(key: $0.text("Key") ?? "", size: Int64($0.text("Size") ?? "") ?? 0,
                         lastModified: $0.text("LastModified").flatMap(S3Date.parse),
                         eTag: $0.text("ETag"), storageClass: $0.text("StorageClass"))
            },
            nextContinuationToken: root.text("IsTruncated") == "true" ? root.text("NextContinuationToken") : nil)
    }

    public func headObject(bucket: String, key: String) async throws(DatabaseError) -> S3ObjectHead {
        let (_, response) = try await send("HEAD", bucket: bucket, key: key)
        let headers = response.allHeaderFields.compactMap { k, v -> KeyValue? in
            guard let k = k as? String else { return nil }
            return KeyValue(key: k, value: "\(v)")
        }
        return S3ObjectHead(headers: headers.sorted { $0.key.lowercased() < $1.key.lowercased() })
    }

    /// Downloads an object, or the first `maxBytes` of it.
    public func getObject(bucket: String, key: String, maxBytes: Int? = nil) async throws(DatabaseError) -> Data {
        var headers: [String: String] = [:]
        if let maxBytes { headers["range"] = "bytes=0-\(max(maxBytes - 1, 0))" }
        return try await send("GET", bucket: bucket, key: key, headers: headers).0
    }

    // MARK: Transport

    func request(method: String, bucket: String?, key: String?, query: [(String, String)] = [],
                 headers: [String: String] = [:], date: Date = .now) -> URLRequest {
        var path = endpoint.path(percentEncoded: true)
        if path.hasSuffix("/") { path.removeLast() }
        if let bucket { path += "/" + S3Signer.uriEncode(bucket) }
        if let key { path += "/" + S3Signer.encodePath(key) }
        if path.isEmpty { path = "/" }
        var host = endpoint.host() ?? ""
        if let port = endpoint.port { host += ":\(port)" }
        var all = headers
        all["host"] = host
        let signed = S3Signer.sign(method: method, encodedPath: path, query: query, headers: all,
                                   credentials: credentials, region: region, date: date)
        let queryString = S3Signer.canonicalQuery(query)
        var request = URLRequest(url: URL(string: "\(endpoint.scheme ?? "https")://\(host)\(path)\(queryString.isEmpty ? "" : "?" + queryString)")!)
        request.httpMethod = method
        for (name, value) in signed where name != "host" { request.setValue(value, forHTTPHeaderField: name) }
        return request
    }

    private func send(_ method: String, bucket: String?, key: String?, query: [(String, String)] = [],
                      headers: [String: String] = [:]) async throws(DatabaseError) -> (Data, HTTPURLResponse) {
        let request = request(method: method, bucket: bucket, key: key, query: query, headers: headers)
        let data: Data, response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            throw DatabaseError(kind: .connection, message: "S3 request failed: \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else { throw DatabaseError(kind: .other, message: "Invalid S3 response.") }
        guard (200..<300).contains(http.statusCode) else { throw Self.error(status: http.statusCode, body: data) }
        return (data, http)
    }

    private func xml(_ response: (Data, HTTPURLResponse)) throws(DatabaseError) -> S3XMLNode {
        guard let root = S3XMLNode.parse(response.0) else { throw DatabaseError(kind: .other, message: "Invalid S3 XML response.") }
        return root
    }

    static func error(status: Int, body: Data) -> DatabaseError {
        let root = S3XMLNode.parse(body)
        let code = root?.text("Code")
        let message = root?.text("Message") ?? HTTPURLResponse.localizedString(forStatusCode: status).capitalized
        return DatabaseError(kind: .server, message: "S3 error \(status): \(message)", detail: code)
    }
}

enum S3Date {
    static func parse(_ text: String) -> Date? {
        (try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
            ?? (try? Date(text, strategy: .iso8601))
    }
}

/// Minimal XML tree, enough for S3 responses.
final class S3XMLNode {
    let name: String
    var children: [S3XMLNode] = []
    var content = ""

    init(name: String) { self.name = name }

    /// Descendants (at any depth) named `name`.
    func all(_ name: String) -> [S3XMLNode] {
        children.flatMap { ($0.name == name ? [$0] : []) + $0.all(name) }
    }

    /// Text of the first direct child named `name`.
    func text(_ name: String) -> String? {
        children.first { $0.name == name }?.content
    }

    static func parse(_ data: Data) -> S3XMLNode? {
        let builder = Builder()
        let parser = XMLParser(data: data)
        parser.delegate = builder
        return parser.parse() ? builder.root : nil
    }

    private final class Builder: NSObject, XMLParserDelegate {
        var root: S3XMLNode?
        var stack: [S3XMLNode] = []

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            let node = S3XMLNode(name: name)
            stack.last?.children.append(node)
            if root == nil { root = node }
            stack.append(node)
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            stack.removeLast()
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            stack.last?.content += string
        }
    }
}
