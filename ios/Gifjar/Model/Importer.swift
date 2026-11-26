import CoreTransferable
import Foundation
import SwiftData
import UniformTypeIdentifiers

/// Turns pasted, dropped, shared, or linked content into saved items.
@Observable
final class Importer {
    struct Outcome {
        var added: [GifjarItem] = []
        var duplicates: [GifjarItem] = []

        mutating func merge(_ other: Outcome) {
            added += other.added
            duplicates += other.duplicates
        }
    }

    private let context: ModelContext
    private let session: URLSession
    var onAdded: ((GifjarItem) -> Void)?
    private var activeImports = 0
    var isImporting: Bool { activeImports > 0 }

    init(context: ModelContext, session: URLSession = .shared) {
        self.context = context
        self.session = session
    }

    // MARK: Entry points

    /// Paste button, drag and drop. Handles images, GIFs, image files, and links.
    func importFromPasteboard(_ providers: [NSItemProvider]) async throws -> Outcome {
        try await run {
            var outcome = Outcome()
            var lastError: Error = ImportError.nothingToImport
            for provider in providers {
                do {
                    outcome.merge(try await self.importIncoming(MediaResolver.incoming(from: provider)))
                } catch {
                    lastError = error
                }
            }
            if outcome.added.isEmpty && outcome.duplicates.isEmpty { throw lastError }
            return outcome
        }
    }

    func importIncoming(_ incoming: IncomingItem) async throws -> Outcome {
        switch incoming {
        case .media(let data): try importData(data)
        case .link(let url): try await importURL(url)
        }
    }

    func importData(_ data: Data, sourceURL: URL? = nil) throws -> Outcome {
        try save(MediaResolver.media(data, sourceURL: sourceURL))
    }

    /// Link import: a direct image URL, or a page whose metadata points at one.
    func importURL(_ url: URL) async throws -> Outcome {
        try await run {
            try self.save(await MediaResolver.resolve(url, session: self.session))
        }
    }

    // MARK: Share extension inbox

    /// Files everything the share extension left in the App Group inbox.
    /// Links the extension couldn't fetch (offline, slow page) are retried here.
    func drainShareInbox() async -> Outcome {
        guard let inbox = ShareInbox.shared else { return Outcome() }
        var outcome = Outcome()
        for (request, folder) in inbox.pending() {
            do {
                let media: ResolvedMedia
                if let data = try inbox.mediaData(for: request, in: folder) {
                    media = try MediaResolver.media(data, sourceURL: request.sourceURL, title: request.title)
                } else if let link = request.link {
                    media = try await run { try await MediaResolver.resolve(link, session: self.session) }
                } else {
                    inbox.remove(folder)
                    continue
                }
                outcome.merge(try save(media, title: request.title, phrase: request.phrase, note: request.note,
                                       favorite: request.isFavorite == true))
                inbox.remove(folder)
            } catch let error as ImportError where error.isPermanent {
                inbox.remove(folder)
            } catch {
                // Network trouble: keep it for the next time the app becomes active.
            }
        }
        return outcome
    }

    // MARK: Internals

    private func run<T>(_ body: () async throws -> T) async throws -> T {
        activeImports += 1
        defer { activeImports -= 1 }
        return try await body()
    }

    @discardableResult
    private func save(_ media: ResolvedMedia, title: String? = nil, phrase: String? = nil, note: String? = nil,
                      favorite: Bool = false) throws -> Outcome {
        let phrase = phrase?.trimmed ?? ""
        let hash = MediaStore.hash(media.data)
        var existing = FetchDescriptor<GifjarItem>(predicate: #Predicate { $0.contentHash == hash && !$0.pendingDeletion })
        existing.fetchLimit = 1
        if let duplicate = try context.fetch(existing).first {
            // Sharing something you already have can still add a phrase to it.
            var changed = false
            if !phrase.isEmpty,
               !duplicate.phrases.contains(where: { $0.caseInsensitiveCompare(phrase) == .orderedSame }) {
                duplicate.phrases.append(phrase)
                changed = true
            }
            if favorite, !duplicate.isFavorite {
                duplicate.isFavorite = true
                changed = true
            }
            if changed {
                duplicate.touch()
                try context.save()
            }
            return Outcome(duplicates: [duplicate])
        }

        let item = GifjarItem(contentType: media.type, info: media.info, byteCount: media.data.count,
                             contentHash: hash, sourceURL: media.sourceURL)
        let typedTitle = title?.trimmed ?? ""
        item.title = typedTitle.isEmpty ? (media.suggestedTitle ?? "") : typedTitle
        if !phrase.isEmpty { item.phrases = [phrase] }
        if let note = note?.trimmed, !note.isEmpty { item.notes = note }
        item.isFavorite = favorite
        try MediaStore.shared.write(media.data, id: item.id, type: media.type)
        context.insert(item)
        try context.save()
        onAdded?(item)
        return Outcome(added: [item])
    }
}

extension Importer {
    /// Everything the Paste button and drop target accept.
    static let pasteTypes: [UTType] = [.gif, .png, .webP, .heic, .jpeg, .image, .fileURL, .url, .plainText]
}

/// Transferable wrapper so ⌘V (`pasteDestination`) can deliver images, GIFs, and links.
/// Representations are tried in order, so animated formats win over flattened stills.
nonisolated enum PastedContent: Transferable {
    case media(Data)
    case link(URL)

    var incoming: IncomingItem {
        switch self {
        case .media(let data): .media(data)
        case .link(let url): .link(url)
        }
    }

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(importedContentType: .gif) { PastedContent.media($0) }
        DataRepresentation(importedContentType: .png) { PastedContent.media($0) }
        DataRepresentation(importedContentType: .webP) { PastedContent.media($0) }
        DataRepresentation(importedContentType: .heic) { PastedContent.media($0) }
        DataRepresentation(importedContentType: .jpeg) { PastedContent.media($0) }
        DataRepresentation(importedContentType: .image) { PastedContent.media($0) }
        ProxyRepresentation(importing: { (url: URL) in PastedContent.link(url) })
        ProxyRepresentation(importing: { (text: String) in
            guard let url = LinkMetadata.firstURL(in: text) else { throw ImportError.nothingToImport }
            return PastedContent.link(url)
        })
    }
}
