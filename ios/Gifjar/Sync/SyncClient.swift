import Foundation
import Security
import UniformTypeIdentifiers

/// Wire format shared with the Worker (`worker/src/index.ts`).
nonisolated struct RemoteItem: Codable, Sendable, Equatable {
    var id: UUID
    var updatedAt: Int64 // ms
    var deleted: Bool?
    var createdAt: Int64?
    var title: String?
    var notes: String?
    var phrases: [String]?
    var isFavorite: Bool?
    var aiSummary: String?
    var aiTags: [String]?
    var ocrText: String?
    var contentType: String?
    var pixelWidth: Int?
    var pixelHeight: Int?
    var frameCount: Int?
    var duration: Double?
    var byteCount: Int?
    var contentHash: String?
    var sourceURL: String?

    enum CodingKeys: String, CodingKey {
        case id, updatedAt, deleted, createdAt, title, notes, phrases, isFavorite, aiSummary, aiTags, ocrText
        case contentType, pixelWidth, pixelHeight, frameCount, duration, byteCount, contentHash, sourceURL
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Worker stores lowercase UUIDs; UUID(uuidString:) accepts both.
        guard let id = UUID(uuidString: try c.decode(String.self, forKey: .id)) else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "Bad UUID")
        }
        self.id = id
        updatedAt = try c.decode(Int64.self, forKey: .updatedAt)
        deleted = try c.decodeIfPresent(Bool.self, forKey: .deleted)
        createdAt = try c.decodeIfPresent(Int64.self, forKey: .createdAt)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        phrases = try c.decodeIfPresent([String].self, forKey: .phrases)
        isFavorite = try c.decodeIfPresent(Bool.self, forKey: .isFavorite)
        aiSummary = try c.decodeIfPresent(String.self, forKey: .aiSummary)
        aiTags = try c.decodeIfPresent([String].self, forKey: .aiTags)
        ocrText = try c.decodeIfPresent(String.self, forKey: .ocrText)
        contentType = try c.decodeIfPresent(String.self, forKey: .contentType)
        pixelWidth = try c.decodeIfPresent(Int.self, forKey: .pixelWidth)
        pixelHeight = try c.decodeIfPresent(Int.self, forKey: .pixelHeight)
        frameCount = try c.decodeIfPresent(Int.self, forKey: .frameCount)
        duration = try c.decodeIfPresent(Double.self, forKey: .duration)
        byteCount = try c.decodeIfPresent(Int.self, forKey: .byteCount)
        contentHash = try c.decodeIfPresent(String.self, forKey: .contentHash)
        sourceURL = try c.decodeIfPresent(String.self, forKey: .sourceURL)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id.uuidString.lowercased(), forKey: .id)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encodeIfPresent(deleted, forKey: .deleted)
        try c.encodeIfPresent(createdAt, forKey: .createdAt)
        try c.encodeIfPresent(title, forKey: .title)
        try c.encodeIfPresent(notes, forKey: .notes)
        try c.encodeIfPresent(phrases, forKey: .phrases)
        try c.encodeIfPresent(isFavorite, forKey: .isFavorite)
        try c.encodeIfPresent(aiSummary, forKey: .aiSummary)
        try c.encodeIfPresent(aiTags, forKey: .aiTags)
        try c.encodeIfPresent(ocrText, forKey: .ocrText)
        try c.encodeIfPresent(contentType, forKey: .contentType)
        try c.encodeIfPresent(pixelWidth, forKey: .pixelWidth)
        try c.encodeIfPresent(pixelHeight, forKey: .pixelHeight)
        try c.encodeIfPresent(frameCount, forKey: .frameCount)
        try c.encodeIfPresent(duration, forKey: .duration)
        try c.encodeIfPresent(byteCount, forKey: .byteCount)
        try c.encodeIfPresent(contentHash, forKey: .contentHash)
        try c.encodeIfPresent(sourceURL, forKey: .sourceURL)
    }

    init(id: UUID, updatedAt: Int64) {
        self.id = id
        self.updatedAt = updatedAt
    }
}

nonisolated struct SyncConfiguration: Sendable, Equatable {
    var baseURL: URL
    var token: String
}

/// Thin HTTP client for the Worker. No state; safe to use from any task.
nonisolated struct SyncClient: Sendable {
    enum ClientError: LocalizedError {
        case unauthorized, conflict(RemoteItem), gone, server(Int, String)

        var errorDescription: String? {
            switch self {
            case .unauthorized: String(localized: "The access token was rejected.")
            case .conflict: String(localized: "A newer version exists on the server.")
            case .gone: String(localized: "This item was deleted on another device.")
            case .server(let code, let message): String(localized: "Server error \(code): \(message)")
            }
        }
    }

    struct ListResponse: Decodable { var items: [RemoteItem]; var serverTime: Int64 }

    let config: SyncConfiguration
    var session: URLSession = .shared

    func health() async throws {
        _ = try await send(request("health"))
    }

    func list(since: Int64) async throws -> ListResponse {
        let data = try await send(request("items?since=\(since)"))
        return try JSONDecoder().decode(ListResponse.self, from: data)
    }

    func putMeta(_ item: RemoteItem) async throws {
        var req = request("items/\(item.id.uuidString.lowercased())", method: "PUT")
        req.httpBody = try JSONEncoder().encode(item)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        _ = try await send(req)
    }

    func delete(_ id: UUID) async throws {
        _ = try await send(request("items/\(id.uuidString.lowercased())", method: "DELETE"))
    }

    func uploadMedia(id: UUID, fileURL: URL, type: UTType) async throws {
        var req = request("items/\(id.uuidString.lowercased())/media", method: "PUT")
        req.setValue(type.preferredMIMEType ?? "application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.upload(for: req, fromFile: fileURL)
        try check(response, data)
    }

    func downloadMedia(id: UUID) async throws -> Data {
        try await send(request("items/\(id.uuidString.lowercased())/media"))
    }

    private func request(_ path: String, method: String = "GET") -> URLRequest {
        let url = URL(string: "v1/\(path)", relativeTo: config.baseURL.appendingSlash)!
        var req = URLRequest(url: url, timeoutInterval: 60)
        req.httpMethod = method
        req.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        return req
    }

    private func send(_ req: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: req)
        try check(response, data)
        return data
    }

    private func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        switch http.statusCode {
        case 200..<300: return
        case 401: throw ClientError.unauthorized
        case 409:
            if let newer = try? JSONDecoder().decode(RemoteItem.self, from: data) { throw ClientError.conflict(newer) }
            throw ClientError.server(409, "Conflict")
        case 410: throw ClientError.gone
        default:
            let message = (try? JSONDecoder().decode([String: String].self, from: data))?["error"] ?? ""
            throw ClientError.server(http.statusCode, message)
        }
    }
}

nonisolated extension URL {
    var appendingSlash: URL {
        absoluteString.hasSuffix("/") ? self : URL(string: absoluteString + "/") ?? self
    }
}

// MARK: - Keychain

/// Stores the Worker token in the Keychain, never in UserDefaults.
nonisolated enum TokenStore {
    private static let service = "dev.jusso.gifjar.sync"
    private static let account = "api-token"

    static func read() -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ token: String?) {
        let base: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard let token, !token.isEmpty else { return }
        var add = base
        add[kSecValueData] = Data(token.utf8)
        add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
}
