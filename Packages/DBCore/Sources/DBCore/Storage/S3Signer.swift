import CryptoKit
import Foundation

/// Credentials for an S3-compatible endpoint.
public struct S3Credentials: Sendable, Hashable {
    public var accessKeyID: String
    public var secretAccessKey: String
    /// Sent as `x-amz-security-token` when present.
    public var sessionToken: String?

    public init(accessKeyID: String, secretAccessKey: String, sessionToken: String? = nil) {
        self.accessKeyID = accessKeyID
        self.secretAccessKey = secretAccessKey
        self.sessionToken = sessionToken
    }
}

/// AWS Signature Version 4, header-based, for the `s3` service.
public enum S3Signer {
    public static let emptyPayloadHash = sha256Hex(Data())

    /// Returns `headers` plus `x-amz-date`, `x-amz-content-sha256`, the session token and `Authorization`.
    /// `headers` must contain `host`; `encodedPath` must already be URI-encoded (see `encodePath`).
    public static func sign(
        method: String, encodedPath: String, query: [(String, String)], headers: [String: String],
        payloadHash: String = emptyPayloadHash, credentials: S3Credentials, region: String, date: Date = .now
    ) -> [String: String] {
        let (amzDate, day) = timestamps(date)
        var all: [String: String] = [:]
        for (key, value) in headers { all[key.lowercased()] = value }
        all["x-amz-date"] = amzDate
        all["x-amz-content-sha256"] = payloadHash
        if let token = credentials.sessionToken { all["x-amz-security-token"] = token }

        let sortedKeys = all.keys.sorted()
        let canonicalHeaders = sortedKeys.map { "\($0):\(all[$0]!.trimmingCharacters(in: .whitespaces))\n" }.joined()
        let signedHeaders = sortedKeys.joined(separator: ";")
        let canonicalRequest = [
            method, encodedPath.isEmpty ? "/" : encodedPath, canonicalQuery(query),
            canonicalHeaders, signedHeaders, payloadHash,
        ].joined(separator: "\n")

        let scope = "\(day)/\(region)/s3/aws4_request"
        let stringToSign = ["AWS4-HMAC-SHA256", amzDate, scope, sha256Hex(Data(canonicalRequest.utf8))].joined(separator: "\n")

        var key = SymmetricKey(data: Data("AWS4\(credentials.secretAccessKey)".utf8))
        for part in [day, region, "s3", "aws4_request"] {
            key = SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: Data(part.utf8), using: key)))
        }
        let signature = HMAC<SHA256>.authenticationCode(for: Data(stringToSign.utf8), using: key).hex

        all["authorization"] = "AWS4-HMAC-SHA256 Credential=\(credentials.accessKeyID)/\(scope), "
            + "SignedHeaders=\(signedHeaders), Signature=\(signature)"
        return all
    }

    /// Sorted `key=value` pairs, both URI-encoded.
    public static func canonicalQuery(_ query: [(String, String)]) -> String {
        let encoded: [(key: String, value: String)] = query.map { (uriEncode($0.0), uriEncode($0.1)) }
        let sorted = encoded.sorted { lhs, rhs in lhs.key == rhs.key ? lhs.value < rhs.value : lhs.key < rhs.key }
        return sorted.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
    }

    /// Encodes each segment of a path, keeping `/`.
    public static func encodePath(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: false).map { uriEncode(String($0)) }.joined(separator: "/")
    }

    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    public static func uriEncode(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? text
    }

    public static func sha256Hex(_ data: Data) -> String { SHA256.hash(data: data).hex }

    private static func timestamps(_ date: Date) -> (String, String) {
        let c = Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "UTC")!, from: date)
        let day = String(format: "%04d%02d%02d", c.year!, c.month!, c.day!)
        return (day + String(format: "T%02d%02d%02dZ", c.hour!, c.minute!, c.second!), day)
    }
}

private extension Sequence where Element == UInt8 {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
