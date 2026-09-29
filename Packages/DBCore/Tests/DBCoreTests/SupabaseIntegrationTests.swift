import Foundation
import Testing
@testable import DBCore

/// Read-only checks against a real Supabase project (connecting creates a temporary CLI login role). Enable with
/// `SUPABASE_ACCESS_TOKEN=… SUPABASE_PROJECT_REF=… swift test --filter SupabaseIntegrationTests`.
private let env = ProcessInfo.processInfo.environment
private let token = env["SUPABASE_ACCESS_TOKEN"], ref = env["SUPABASE_PROJECT_REF"]

@Suite(.enabled(if: token != nil && ref != nil), .serialized)
struct SupabaseIntegrationTests {
    @Test func postgresWithAccessTokenOnly() async throws {
        let resolved = try await SupabaseProject.resolvePostgres(
            ConnectionConfig(supabase: SupabaseConfig(projectRef: ref!)), accessToken: token!)
        let session = DatabaseSession(config: resolved.config, secrets: .init(password: resolved.password))
        try await session.connect()
        let schemas = try await session.schemas(includeSystem: false).map(\.name)
        #expect(schemas.contains("auth"))
        #expect(schemas.contains("storage"))
        let relations = try await session.relations(schema: "storage")
        let buckets = try #require(relations.first { $0.name == "buckets" })
        // The temporary login role only reads data after `SET ROLE postgres`.
        #expect(try await session.rows("SELECT current_user").first?.first?.text == "postgres")
        let rows = try await session.fetchPage(TableQuery(structure: try await session.structure(of: buckets), pageSize: 5))
        #expect(!rows.isEmpty)
        await session.close()
    }

    @Test func storageThroughS3() async throws {
        let client = try await SupabaseProject.storageClient(SupabaseConfig(projectRef: ref!), accessToken: token!)
        let buckets = try await client.listBuckets()
        #expect(!buckets.isEmpty)
        let listing = try await client.listObjects(bucket: buckets[0].name, maxKeys: 5)
        if let first = listing.objects.first {
            let head = try await client.headObject(bucket: buckets[0].name, key: first.key)
            #expect(head.contentLength == first.size)
            let bytes = try await client.getObject(bucket: buckets[0].name, key: first.key, maxBytes: 16)
            #expect(bytes.count == min(16, Int(first.size)))
        }
    }

    @Test func edgeFunctions() async throws {
        let functions = try await SupabaseAPI(accessToken: token!).functions(ref!)
        #expect(functions.allSatisfy { !$0.slug.isEmpty && !$0.fields.isEmpty })
    }
}
