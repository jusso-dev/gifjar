import Foundation
import Observation
import SwiftData

/// Runs on-device analysis one item at a time so the model isn't contended.
@Observable
final class AnalysisQueue {
    private(set) var activeID: UUID?
    private var pending: [UUID] = []
    private var worker: Task<Void, Never>?
    private let context: ModelContext
    var onItemAnalyzed: (() -> Void)?

    init(context: ModelContext) {
        self.context = context
    }

    func enqueue(_ item: StashItem) {
        guard !pending.contains(item.id), activeID != item.id else { return }
        item.analysisState = .pending
        pending.append(item.id)
        start()
    }

    /// Picks up anything left unfinished by a previous launch.
    func resumeUnfinished() {
        let descriptor = FetchDescriptor<StashItem>(predicate: #Predicate {
            !$0.pendingDeletion
        })
        let items = (try? context.fetch(descriptor)) ?? []
        for item in items where item.analysisState == .pending || item.analysisState == .analyzing {
            enqueue(item)
        }
    }

    private func start() {
        guard worker == nil else { return }
        worker = Task { [weak self] in
            while let self, let id = self.nextID() {
                await self.process(id)
            }
            self?.worker = nil
        }
    }

    private func nextID() -> UUID? {
        guard !pending.isEmpty else { return nil }
        return pending.removeFirst()
    }

    private func process(_ id: UUID) async {
        guard let item = fetch(id), MediaStore.shared.exists(id: id, type: item.contentType) else { return }
        activeID = id
        defer { activeID = nil }
        item.analysisState = .analyzing

        do {
            let result = try await ImageAnalyzer.analyze(fileURL: item.fileURL)
            // The item may have been deleted while we were thinking.
            guard let item = fetch(id) else { return }
            apply(result, to: item)
        } catch {
            fetch(id)?.analysisState = .failed
        }
        try? context.save()
        onItemAnalyzed?()
    }

    private func apply(_ result: AnalysisResult, to item: StashItem) {
        item.aiSummary = result.summary
        item.aiTags = result.tags
        item.ocrText = result.ocrText
        // Only fill user-facing fields the user hasn't written themselves.
        if item.title.isEmpty, !result.title.isEmpty { item.title = result.title }
        for phrase in result.reactions where !item.phrases.contains(where: { $0.caseInsensitiveCompare(phrase) == .orderedSame }) {
            item.phrases.append(phrase)
        }
        item.analysisState = .done
        item.touch()
    }

    private func fetch(_ id: UUID) -> StashItem? {
        var descriptor = FetchDescriptor<StashItem>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }
}
