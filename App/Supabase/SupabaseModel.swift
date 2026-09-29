import AppKit
import DBCore
import OSLog
import Foundation

/// Non-Postgres parts of a Supabase project: Storage through its S3 endpoint, and Edge Functions.
@Observable
final class SupabaseModel {
    let config: SupabaseConfig
    private let accessToken: String
    private(set) var storage: S3Client?
    private(set) var buckets: [S3Bucket] = []
    private(set) var functions: [SupabaseFunction] = []
    private(set) var storageError: String?
    private(set) var functionsError: String?

    init(config: SupabaseConfig, accessToken: String) {
        self.config = config
        self.accessToken = accessToken
    }

    func load() async {
        async let storage: Void = loadStorage()
        async let functions: Void = loadFunctions()
        _ = await (storage, functions)
    }

    private func loadStorage() async {
        do {
            let client: S3Client
            if let storage {
                client = storage
            } else {
                client = try await SupabaseProject.storageClient(config, accessToken: accessToken)
                storage = client
            }
            buckets = try await client.listBuckets().sorted { $0.name < $1.name }
            storageError = nil
        } catch {
            storageError = error.fullDescription
            appLogger.error("Storage for \(self.config.projectRef, privacy: .public) failed: \(error.fullDescription, privacy: .public)")
        }
    }

    private func loadFunctions() async {
        do {
            functions = try await SupabaseAPI(accessToken: accessToken).functions(config.projectRef)
            functionsError = nil
        } catch {
            functionsError = error.fullDescription
            appLogger.error("Edge Functions for \(self.config.projectRef, privacy: .public) failed: \(error.fullDescription, privacy: .public)")
        }
    }
}

/// A row of the bucket browser: a "folder" (common prefix) or an object.
struct BucketEntry: Identifiable, Hashable {
    /// Full key, or full prefix ending in the delimiter.
    let id: String
    let name: String
    let object: S3Object?
    var isFolder: Bool { object == nil }
}

/// A bucket opened in a tab, browsed one prefix level at a time.
@Observable
final class BucketTabModel {
    enum Preview {
        case image(NSImage)
        case text(String)
        case unavailable(String)
    }

    /// Objects larger than this are not previewed.
    static let previewLimit = 5 * 1024 * 1024

    let id = UUID()
    let bucket: String
    let client: S3Client
    private(set) var prefix = ""
    private(set) var entries: [BucketEntry] = []
    private(set) var nextToken: String?
    private(set) var isLoading = false
    private(set) var error: String?
    var selection: Set<String> = [] {
        didSet { Task { await inspectSelection() } }
    }
    private(set) var head: S3ObjectHead?
    private(set) var preview: Preview?
    private(set) var inspectError: String?

    init(bucket: String, client: S3Client) {
        self.bucket = bucket
        self.client = client
    }

    /// `bucket/prefix` path components, for the breadcrumb: (label, prefix).
    var breadcrumbs: [(String, String)] {
        var result = [(bucket, "")]
        var path = ""
        for part in prefix.split(separator: "/") {
            path += part + "/"
            result.append((String(part), path))
        }
        return result
    }

    var selectedObject: S3Object? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return entries.first { $0.id == id }?.object
    }

    func open(prefix: String) async {
        self.prefix = prefix
        selection = []
        await load()
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let listing = try await client.listObjects(bucket: bucket, prefix: prefix)
            entries = Self.entries(listing, prefix: prefix)
            nextToken = listing.nextContinuationToken
            error = nil
        } catch {
            entries = []
            nextToken = nil
            self.error = error.fullDescription
        }
    }

    func loadMore() async {
        guard let token = nextToken else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let listing = try await client.listObjects(bucket: bucket, prefix: prefix, continuationToken: token)
            entries += Self.entries(listing, prefix: prefix)
            nextToken = listing.nextContinuationToken
        } catch {
            self.error = error.fullDescription
        }
    }

    private static func entries(_ listing: S3ObjectListing, prefix: String) -> [BucketEntry] {
        listing.commonPrefixes.map { BucketEntry(id: $0, name: String($0.dropFirst(prefix.count)), object: nil) }
            + listing.objects.map { BucketEntry(id: $0.key, name: String($0.key.dropFirst(prefix.count)), object: $0) }
    }

    private func inspectSelection() async {
        guard let object = selectedObject else {
            head = nil
            preview = nil
            inspectError = nil
            return
        }
        do {
            let head = try await client.headObject(bucket: bucket, key: object.key)
            guard selectedObject == object else { return }
            self.head = head
            inspectError = nil
            preview = try await makePreview(object, contentType: head.contentType ?? "")
        } catch {
            guard selectedObject == object else { return }
            inspectError = error.fullDescription
        }
    }

    private func makePreview(_ object: S3Object, contentType: String) async throws(DatabaseError) -> Preview? {
        let isImage = contentType.hasPrefix("image/")
        let isText = contentType.hasPrefix("text/") || contentType.contains("json") || contentType.contains("xml")
            || contentType.contains("javascript")
        guard isImage || isText else { return nil }
        guard object.size <= Self.previewLimit else {
            return .unavailable("Too large to preview (\(object.size.formatted(.byteCount(style: .file))))")
        }
        let data = try await client.getObject(bucket: bucket, key: object.key)
        guard selectedObject == object else { return preview }
        if isImage {
            return NSImage(data: data).map(Preview.image) ?? .unavailable("Not a readable image.")
        }
        return .text(String(decoding: data, as: UTF8.self))
    }

    func download(_ object: S3Object) async throws(DatabaseError) -> Data {
        try await client.getObject(bucket: bucket, key: object.key)
    }
}

/// An Edge Function opened in a tab: every field returned by the Management API.
struct EdgeFunctionTab: Identifiable {
    let id = UUID()
    let function: SupabaseFunction
}
