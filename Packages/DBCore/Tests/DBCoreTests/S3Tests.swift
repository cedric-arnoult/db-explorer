import Foundation
import Testing
@testable import DBCore

@Suite struct S3Tests {
    // Examples from https://docs.aws.amazon.com/AmazonS3/latest/API/sig-v4-header-based-auth.html
    let credentials = S3Credentials(accessKeyID: "AKIAIOSFODNN7EXAMPLE", secretAccessKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY")
    let date = Date(timeIntervalSince1970: 1_369_353_600) // 2013-05-24T00:00:00Z

    @Test func signsGetObjectExample() {
        let headers = S3Signer.sign(
            method: "GET", encodedPath: "/test.txt", query: [],
            headers: ["Host": "examplebucket.s3.amazonaws.com", "Range": "bytes=0-9"],
            credentials: credentials, region: "us-east-1", date: date)
        #expect(headers["authorization"] == "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, SignedHeaders=host;range;x-amz-content-sha256;x-amz-date, Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41")
        #expect(headers["x-amz-date"] == "20130524T000000Z")
    }

    @Test func signsListObjectsExample() {
        let headers = S3Signer.sign(
            method: "GET", encodedPath: "/", query: [("prefix", "J"), ("max-keys", "2")],
            headers: ["host": "examplebucket.s3.amazonaws.com"],
            credentials: credentials, region: "us-east-1", date: date)
        #expect(headers["authorization"]?.hasSuffix("Signature=34b48302e7b5fa45bde8084f4b7868a86f0a534bc59db6670ed5711ef69dc6f7") == true)
    }

    @Test func sessionTokenIsSigned() {
        let headers = S3Signer.sign(
            method: "GET", encodedPath: "/", query: [], headers: ["host": "h"],
            credentials: S3Credentials(accessKeyID: "a", secretAccessKey: "b", sessionToken: "tok"), region: "r", date: date)
        #expect(headers["x-amz-security-token"] == "tok")
        #expect(headers["authorization"]?.contains("x-amz-security-token") == true)
    }

    @Test func encoding() {
        #expect(S3Signer.encodePath("/a b/ü+c=/") == "/a%20b/%C3%BC%2Bc%3D/")
        #expect(S3Signer.canonicalQuery([("prefix", "a/b c"), ("delimiter", "/"), ("list-type", "2")])
            == "delimiter=%2F&list-type=2&prefix=a%2Fb%20c")
    }

    @Test func requestURLUsesPathStyleUnderEndpoint() {
        let client = S3Client(endpoint: URL(string: "https://ref.storage.supabase.co/storage/v1/s3")!, region: "eu-west-1",
                              credentials: credentials)
        let request = client.request(method: "GET", bucket: "my bucket", key: "dir/file 1.png", query: [("x-id", "GetObject")])
        #expect(request.url?.absoluteString == "https://ref.storage.supabase.co/storage/v1/s3/my%20bucket/dir/file%201.png?x-id=GetObject")
        #expect(request.value(forHTTPHeaderField: "Authorization")?.contains("/eu-west-1/s3/") == true)
    }

    @Test func parsesListing() throws {
        let xml = """
            <?xml version="1.0" encoding="UTF-8"?><ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">\
            <Name>b</Name><IsTruncated>true</IsTruncated><NextContinuationToken>tok</NextContinuationToken>\
            <Contents><Key>a.txt</Key><LastModified>2026-07-07T10:05:45.556Z</LastModified><ETag>"e"</ETag><Size>12</Size></Contents>\
            <CommonPrefixes><Prefix>dir/</Prefix></CommonPrefixes></ListBucketResult>
            """
        let root = try #require(S3XMLNode.parse(Data(xml.utf8)))
        #expect(root.all("Contents").first?.text("Key") == "a.txt")
        #expect(root.all("CommonPrefixes").compactMap { $0.text("Prefix") } == ["dir/"])
        #expect(root.text("NextContinuationToken") == "tok")
        #expect(S3Date.parse("2026-07-07T10:05:45.556Z") != nil)
        #expect(S3Date.parse("2026-07-07T10:05:45Z") != nil)
    }

    @Test func parsesError() {
        let error = S3Client.error(status: 403, body: Data("<Error><Code>AccessDenied</Code><Message>Nope</Message></Error>".utf8))
        #expect(error.message == "S3 error 403: Nope")
        #expect(error.detail == "AccessDenied")
    }
}

@Suite struct SupabaseTests {
    @Test func projectRefFromVariousInputs() {
        let ref = "abcdefghijklmnopqrst"
        #expect(SupabaseProject.projectRef(from: ref) == ref)
        #expect(SupabaseProject.projectRef(from: "https://\(ref).supabase.co") == ref)
        #expect(SupabaseProject.projectRef(from: "https://supabase.com/dashboard/project/\(ref)/editor") == ref)
        #expect(SupabaseProject.projectRef(from: "db.\(ref).supabase.co") == ref)
        #expect(SupabaseProject.projectRef(from: "postgresql://postgres.\(ref):pw@aws-0-eu-west-1.pooler.supabase.com:6543/postgres") == ref)
        #expect(SupabaseProject.projectRef(from: "localhost") == nil)
    }

    @Test func poolerUsesSessionModeAndTLS() {
        var config = ConnectionConfig(tlsMode: .disable, sshTunnel: SSHTunnelConfig(host: "bastion"), supabase: SupabaseConfig(projectRef: "ref"))
        let pooler = SupabasePooler(databaseType: "PRIMARY", dbUser: "postgres.ref", dbHost: "aws-0-eu-west-1.pooler.supabase.com",
                                    dbPort: 6543, dbName: "postgres", poolMode: "transaction")
        SupabaseProject.applyPooler(pooler, role: "cli_login_postgres", projectRef: "ref", to: &config)
        #expect(config.host == "aws-0-eu-west-1.pooler.supabase.com")
        #expect(config.port == 5432)
        #expect(config.user == "cli_login_postgres.ref")
        #expect(config.database == "postgres")
        #expect(config.tlsMode == .require)
        #expect(config.sshTunnel == nil)
        #expect(config.summary == "Supabase · ref")
        #expect(config.sessionRole == "postgres")
        #expect(DatabaseSession.setRoleSQL("postgres") == #"SET ROLE "postgres""#)
        config.database = "other"
        SupabaseProject.applyPooler(pooler, role: "r", projectRef: "ref", to: &config)
        #expect(config.database == "other")
    }

    @Test func describesJSONValues() {
        #expect(SupabaseAPI.describe(true) == "true")
        #expect(SupabaseAPI.describe(288) == "288")
        #expect(SupabaseAPI.describe(NSNull()) == "null")
        #expect(SupabaseAPI.describe(["a": 1]) == #"{"a":1}"#)
    }
}
