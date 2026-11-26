import Foundation
import SwiftData
import UniformTypeIdentifiers

/// One saved image or GIF.
///
/// The original bytes live on disk in `MediaStore` (and in R2 once synced);
/// this model holds everything searchable about it.
@Model
final class GifjarItem {
    @Attribute(.unique) var id: UUID
    var createdAt: Date
    /// Bumped on every user or AI edit; drives last-writer-wins sync.
    var updatedAt: Date

    // User-authored
    var title: String
    var notes: String
    /// Things you'd type to find this again: "this is fine", "mood", "deal with it".
    var phrases: [String]
    var isFavorite: Bool

    // Apple Intelligence / Vision
    var aiSummary: String
    var aiTags: [String]
    var ocrText: String
    var analysisState: AnalysisState

    // Media facts
    var contentTypeIdentifier: String
    var pixelWidth: Int
    var pixelHeight: Int
    var frameCount: Int
    var duration: Double
    var byteCount: Int
    var contentHash: String
    var sourceURL: String?

    // Sync bookkeeping
    var needsSync: Bool
    var mediaUploaded: Bool
    /// Soft delete: hidden from the UI until the server confirms, then removed.
    var pendingDeletion: Bool
    var lastUsedAt: Date?

    init(
        id: UUID = UUID(),
        contentType: UTType,
        info: MediaInfo,
        byteCount: Int,
        contentHash: String,
        sourceURL: URL? = nil,
        title: String = ""
    ) {
        self.id = id
        self.createdAt = .now
        self.updatedAt = .now
        self.title = title
        self.notes = ""
        self.phrases = []
        self.isFavorite = false
        self.aiSummary = ""
        self.aiTags = []
        self.ocrText = ""
        self.analysisState = .pending
        self.contentTypeIdentifier = contentType.identifier
        self.pixelWidth = info.pixelWidth
        self.pixelHeight = info.pixelHeight
        self.frameCount = info.frameCount
        self.duration = info.duration
        self.byteCount = byteCount
        self.contentHash = contentHash
        self.sourceURL = sourceURL?.absoluteString
        self.needsSync = true
        self.mediaUploaded = false
        self.pendingDeletion = false
    }

    enum AnalysisState: String, Codable {
        case pending, analyzing, done, failed
    }
}

extension GifjarItem {
    var contentType: UTType { UTType(contentTypeIdentifier) ?? .image }
    var isAnimated: Bool { frameCount > 1 }
    var isGIF: Bool { contentType.conforms(to: .gif) }

    /// Width / height, clamped so a corrupt file can't produce a zero-height cell.
    var aspectRatio: CGFloat {
        guard pixelWidth > 0, pixelHeight > 0 else { return 1 }
        return min(max(CGFloat(pixelWidth) / CGFloat(pixelHeight), 0.25), 4)
    }

    var displayTitle: String {
        if !title.isEmpty { return title }
        if let first = phrases.first { return first }
        if !aiSummary.isEmpty { return aiSummary }
        return isAnimated ? String(localized: "Untitled GIF") : String(localized: "Untitled Image")
    }

    var kindLabel: String {
        if isGIF { return "GIF" }
        if isAnimated { return String(localized: "Animated") }
        return contentType.localizedDescription ?? String(localized: "Image")
    }

    var fileURL: URL { MediaStore.shared.url(for: id, type: contentType) }

    /// Call after any edit so the change syncs and wins conflicts.
    func touch() {
        updatedAt = .now
        needsSync = true
    }
}
