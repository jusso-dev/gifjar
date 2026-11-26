import Foundation
import UniformTypeIdentifiers

/// Why something couldn't be added. Shared by the app and the share extension.
nonisolated enum ImportError: LocalizedError, Equatable {
    case nothingToImport
    case notAnImage
    case tooLarge
    case noImageAtURL
    case badURL
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .nothingToImport: String(localized: "There’s no image, GIF, or link to add.")
        case .notAnImage: String(localized: "That file isn’t an image Gifjar can read.")
        case .tooLarge: String(localized: "That file is larger than 50 MB.")
        case .noImageAtURL: String(localized: "Couldn’t find an image or GIF on that page.")
        case .badURL: String(localized: "That doesn’t look like a web address.")
        case .http(let code): String(localized: "The website responded with error \(code).")
        }
    }

    /// Retrying won't help; drop the request instead of keeping it queued.
    var isPermanent: Bool {
        switch self {
        case .http(let code): (400..<500).contains(code) && code != 408 && code != 429
        default: true
        }
    }
}

/// Something shared, pasted, or dropped, before any network work.
nonisolated enum IncomingItem: Sendable, Equatable {
    case media(Data)
    case link(URL)
}

/// Image bytes ready to save, with what we learned on the way.
nonisolated struct ResolvedMedia: Sendable {
    var data: Data
    var type: UTType
    var info: MediaInfo
    var sourceURL: URL?
    /// Page title, when the media came from a web page.
    var suggestedTitle: String?
}

nonisolated enum MediaResolver {
    static let maxBytes = 50 * 1024 * 1024
    /// Order matters: animated formats first so a GIF is never flattened to a still.
    static let preferredTypes: [UTType] = [.gif, .png, .webP, .heic, .heif, .jpeg, .image]

    // MARK: Item providers (paste, drop, share sheet)

    static func incoming(from provider: NSItemProvider) async throws -> IncomingItem {
        let registered = provider.registeredContentTypes
        if let type = preferredTypes.first(where: { want in registered.contains { $0.conforms(to: want) } }) {
            let exact = registered.first { $0.conforms(to: type) } ?? type
            return .media(try await provider.loadData(for: exact))
        }
        if provider.canLoadObject(ofClass: URL.self), let url = try await provider.loadURL() {
            if url.isFileURL {
                return .media(try Data(contentsOf: url, options: .mappedIfSafe))
            }
            return .link(url)
        }
        if provider.canLoadObject(ofClass: String.self), let text = try await provider.loadString(),
           let url = LinkMetadata.firstURL(in: text) {
            return .link(url)
        }
        throw ImportError.nothingToImport
    }

    // MARK: Bytes and links

    static func media(_ data: Data, sourceURL: URL? = nil, title: String? = nil) throws -> ResolvedMedia {
        guard data.count <= maxBytes else { throw ImportError.tooLarge }
        guard let (type, info) = MediaInfo.probe(data) else { throw ImportError.notAnImage }
        return ResolvedMedia(data: data, type: type, info: info, sourceURL: sourceURL, suggestedTitle: title)
    }

    /// A direct image URL, or a page (GIPHY, Tenor, Imgur, articles…) whose metadata points at one.
    @concurrent
    static func resolve(_ url: URL, session: URLSession = .shared) async throws -> ResolvedMedia {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            throw ImportError.badURL
        }
        let (data, response) = try await fetch(url, session: session)
        if let media = try? media(data, sourceURL: url) { return media }

        guard
            response.mimeType?.contains("html") == true,
            let html = String(data: data.prefix(2_000_000), encoding: .utf8)
                ?? String(data: data.prefix(2_000_000), encoding: .isoLatin1)
        else { throw ImportError.notAnImage }

        let title = LinkMetadata.title(in: html)
        for candidate in LinkMetadata.mediaCandidates(in: html, baseURL: response.url ?? url) {
            guard let (bytes, _) = try? await fetch(candidate, session: session),
                  let media = try? media(bytes, sourceURL: url, title: title) else { continue }
            return media
        }
        throw ImportError.noImageAtURL
    }

    private static func fetch(_ url: URL, session: URLSession) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url, timeoutInterval: 30)
        // Many GIF hosts serve a lighter page or block unknown agents.
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 27_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/27.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        request.setValue("image/gif,image/webp,image/apng,image/*,text/html;q=0.9,*/*;q=0.5", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ImportError.http(http.statusCode)
        }
        guard data.count <= maxBytes else { throw ImportError.tooLarge }
        return (data, response)
    }
}

// MARK: - NSItemProvider async helpers

nonisolated extension NSItemProvider {
    func loadData(for type: UTType) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            _ = loadDataRepresentation(for: type) { data, error in
                if let data { continuation.resume(returning: data) }
                else { continuation.resume(throwing: error ?? ImportError.notAnImage) }
            }
        }
    }

    func loadURL() async throws -> URL? {
        try await withCheckedThrowingContinuation { continuation in
            _ = loadObject(ofClass: URL.self) { url, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: url) }
            }
        }
    }

    func loadString() async throws -> String? {
        try await withCheckedThrowingContinuation { continuation in
            _ = loadObject(ofClass: String.self) { text, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: text) }
            }
        }
    }
}
