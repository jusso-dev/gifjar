import Foundation
import Observation
import SwiftData
import UniformTypeIdentifiers

/// Offline-first sync with the Worker: local edits push, remote changes pull,
/// last writer wins by `updatedAt`, deletes travel as tombstones.
@Observable
final class SyncEngine {
    enum Status: Equatable {
        case notConfigured, idle, syncing, offline(String), failed(String)
    }

    private(set) var status: Status = .notConfigured
    private(set) var lastSynced: Date?

    var serverURLString: String {
        didSet { UserDefaults.standard.set(serverURLString, forKey: Keys.server) }
    }

    /// Lets the app describe items that arrived from another device without analysis.
    var onMediaDownloaded: ((StashItem) -> Void)?

    private let context: ModelContext
    private var running: Task<Void, Never>?
    private var rerunRequested = false

    private enum Keys {
        static let server = "sync.serverURL"
        static let cursor = "sync.cursor"
    }

    init(context: ModelContext) {
        self.context = context
        self.serverURLString = UserDefaults.standard.string(forKey: Keys.server) ?? ""
        self.status = configuration == nil ? .notConfigured : .idle
    }

    var configuration: SyncConfiguration? {
        guard let url = URL(string: serverURLString.trimmed), url.scheme?.hasPrefix("http") == true,
              let token = TokenStore.read(), !token.isEmpty else { return nil }
        return SyncConfiguration(baseURL: url, token: token)
    }

    var hasToken: Bool { TokenStore.read()?.isEmpty == false }

    func updateToken(_ token: String) {
        TokenStore.write(token.trimmed)
        status = configuration == nil ? .notConfigured : .idle
    }

    func disconnect() {
        TokenStore.write(nil)
        UserDefaults.standard.removeObject(forKey: Keys.cursor)
        status = .notConfigured
    }

    func testConnection() async throws {
        guard let config = configuration else { throw SyncClient.ClientError.unauthorized }
        try await SyncClient(config: config).health()
    }

    /// Coalesces bursts of edits into one pass.
    func requestSync() {
        guard configuration != nil else { status = .notConfigured; return }
        if running != nil { rerunRequested = true; return }
        running = Task { [weak self] in
            guard let self else { return }
            repeat {
                self.rerunRequested = false
                await self.syncOnce()
            } while self.rerunRequested
            self.running = nil
        }
    }

    // MARK: Sync pass

    private func syncOnce() async {
        guard let config = configuration else { status = .notConfigured; return }
        let client = SyncClient(config: config)
        status = .syncing
        do {
            try await push(client)
            try await pull(client)
            try await fetchMissingMedia(client)
            try context.save()
            lastSynced = .now
            status = .idle
        } catch let error as URLError {
            status = .offline(error.localizedDescription)
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    private func push(_ client: SyncClient) async throws {
        let dirty = try context.fetch(FetchDescriptor<StashItem>(predicate: #Predicate { $0.needsSync }))
        for item in dirty {
            let id = item.id
            if item.pendingDeletion {
                try await client.delete(id)
                MediaStore.shared.delete(id: id, type: item.contentType)
                context.delete(item)
                continue
            }
            do {
                if !item.mediaUploaded, MediaStore.shared.exists(id: id, type: item.contentType) {
                    try await client.uploadMedia(id: id, fileURL: item.fileURL, type: item.contentType)
                    item.mediaUploaded = true
                }
                try await client.putMeta(Self.remote(from: item))
                item.needsSync = false
            } catch SyncClient.ClientError.conflict(let newer) {
                // A tombstone means another device deleted it; don't resurrect.
                if newer.deleted == true { removeLocally(item) } else { apply(newer, to: item) }
            } catch SyncClient.ClientError.gone {
                removeLocally(item)
            }
        }
        try context.save()
    }

    private func pull(_ client: SyncClient) async throws {
        let cursor = Int64(UserDefaults.standard.integer(forKey: Keys.cursor))
        let response = try await client.list(since: cursor)
        for remote in response.items {
            let id = remote.id
            var descriptor = FetchDescriptor<StashItem>(predicate: #Predicate { $0.id == id })
            descriptor.fetchLimit = 1
            let local = try context.fetch(descriptor).first

            if remote.deleted == true {
                if let local { removeLocally(local) }
                continue
            }
            if let local {
                // Local unsynced edit that is newer wins; it'll push next pass.
                if local.needsSync && Self.millis(local.updatedAt) > remote.updatedAt { continue }
                apply(remote, to: local)
            } else if let item = Self.makeItem(from: remote) {
                context.insert(item)
            }
        }
        // Small overlap guards against clock skew between list and writes.
        UserDefaults.standard.set(Int(max(response.serverTime - 5_000, 0)), forKey: Keys.cursor)
    }

    private func fetchMissingMedia(_ client: SyncClient) async throws {
        let all = try context.fetch(FetchDescriptor<StashItem>(predicate: #Predicate { !$0.pendingDeletion && $0.mediaUploaded }))
        for item in all where !MediaStore.shared.exists(id: item.id, type: item.contentType) {
            let data = try await client.downloadMedia(id: item.id)
            try MediaStore.shared.write(data, id: item.id, type: item.contentType)
            if item.analysisState == .pending { onMediaDownloaded?(item) }
        }
    }

    private func removeLocally(_ item: StashItem) {
        MediaStore.shared.delete(id: item.id, type: item.contentType)
        context.delete(item)
    }

    // MARK: Mapping

    static func millis(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }
    static func date(_ millis: Int64) -> Date { Date(timeIntervalSince1970: Double(millis) / 1000) }

    static func remote(from item: StashItem) -> RemoteItem {
        var r = RemoteItem(id: item.id, updatedAt: millis(item.updatedAt))
        r.createdAt = millis(item.createdAt)
        r.title = item.title
        r.notes = item.notes
        r.phrases = item.phrases
        r.isFavorite = item.isFavorite
        r.aiSummary = item.aiSummary
        r.aiTags = item.aiTags
        r.ocrText = item.ocrText
        r.contentType = item.contentTypeIdentifier
        r.pixelWidth = item.pixelWidth
        r.pixelHeight = item.pixelHeight
        r.frameCount = item.frameCount
        r.duration = item.duration
        r.byteCount = item.byteCount
        r.contentHash = item.contentHash
        r.sourceURL = item.sourceURL
        return r
    }

    static func makeItem(from r: RemoteItem) -> StashItem? {
        guard let typeID = r.contentType, let type = UTType(typeID) else { return nil }
        let info = MediaInfo(
            pixelWidth: r.pixelWidth ?? 0, pixelHeight: r.pixelHeight ?? 0,
            frameCount: r.frameCount ?? 1, duration: r.duration ?? 0
        )
        let item = StashItem(id: r.id, contentType: type, info: info, byteCount: r.byteCount ?? 0,
                             contentHash: r.contentHash ?? "", sourceURL: r.sourceURL.flatMap(URL.init(string:)))
        item.createdAt = r.createdAt.map(date) ?? .now
        apply(r, toFields: item)
        item.mediaUploaded = true
        item.analysisState = (r.aiTags?.isEmpty == false || r.aiSummary?.isEmpty == false) ? .done : .pending
        return item
    }

    private func apply(_ r: RemoteItem, to item: StashItem) {
        Self.apply(r, toFields: item)
    }

    private static func apply(_ r: RemoteItem, toFields item: StashItem) {
        item.title = r.title ?? item.title
        item.notes = r.notes ?? item.notes
        item.phrases = r.phrases ?? item.phrases
        item.isFavorite = r.isFavorite ?? item.isFavorite
        item.aiSummary = r.aiSummary ?? item.aiSummary
        item.aiTags = r.aiTags ?? item.aiTags
        item.ocrText = r.ocrText ?? item.ocrText
        item.updatedAt = date(r.updatedAt)
        item.needsSync = false
    }
}
