import Foundation
import UniformTypeIdentifiers

/// One thing sent from the share sheet, waiting for the app to file it.
nonisolated struct ShareRequest: Codable, Sendable, Equatable {
    var id = UUID()
    var createdAt = Date()
    /// File name of the image bytes inside the request folder, when we already have them.
    var mediaFile: String?
    /// A link the extension couldn't fetch (offline, slow site); the app retries it.
    var link: URL?
    var sourceURL: URL?
    var title: String?
    var phrase: String?
    var note: String?
}

/// A folder in the App Group container that the share extension writes to and the app drains.
/// Files, not a shared database, so the two processes never contend for the SwiftData store.
nonisolated struct ShareInbox: Sendable {
    static let appGroup = "group.dev.jusso.stash"
    private static let manifest = "request.json"

    let directory: URL

    /// Nil when the App Group entitlement is missing (e.g. signing not set up).
    static var shared: ShareInbox? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup)
            .map { ShareInbox(directory: $0.appending(path: "Inbox", directoryHint: .isDirectory)) }
    }

    init(directory: URL) {
        self.directory = directory
    }

    /// Writes into a hidden staging folder, then renames, so the app never sees half a request.
    func enqueue(_ request: ShareRequest, media: Data? = nil, type: UTType? = nil) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = request.id.uuidString.lowercased()
        let staging = directory.appending(path: ".\(name)", directoryHint: .isDirectory)
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)

        var request = request
        if let media {
            let file = "media.\(type?.preferredFilenameExtension ?? "img")"
            try media.write(to: staging.appending(path: file))
            request.mediaFile = file
        }
        try JSONEncoder().encode(request).write(to: staging.appending(path: Self.manifest))
        try fm.moveItem(at: staging, to: directory.appending(path: name, directoryHint: .isDirectory))
    }

    /// Complete requests, oldest first.
    func pending() -> [(request: ShareRequest, folder: URL)] {
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        return folders
            .compactMap { folder in
                guard let data = try? Data(contentsOf: folder.appending(path: Self.manifest)),
                      let request = try? JSONDecoder().decode(ShareRequest.self, from: data) else { return nil }
                return (request, folder)
            }
            .sorted { $0.request.createdAt < $1.request.createdAt }
    }

    func mediaData(for request: ShareRequest, in folder: URL) throws -> Data? {
        guard let file = request.mediaFile else { return nil }
        return try Data(contentsOf: folder.appending(path: file), options: .mappedIfSafe)
    }

    func remove(_ folder: URL) {
        try? FileManager.default.removeItem(at: folder)
    }
}
