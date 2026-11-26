import Foundation
import Observation
import SwiftData
import UIKit
import UniformTypeIdentifiers

struct Toast: Equatable, Identifiable {
    let id = UUID()
    var message: String
    var systemImage: String
    var itemID: UUID?
    var isProgress = false
}

/// App-wide state shared by every layout, so folding or unfolding an iPhone Duo
/// keeps the same selection, search, and in-flight work.
@Observable
final class AppModel {
    let container: ModelContainer
    let importer: Importer
    let analysis: AnalysisQueue
    let sync: SyncEngine

    var selection: UUID?
    var searchText = ""
    var filter: LibraryFilter = .all
    var sort: LibrarySort = .newest
    var toast: Toast?
    var errorMessage: String?
    var showingAddLink = false
    var showingSettings = false

    @ObservationIgnored private var syncDebounce: Task<Void, Never>?
    @ObservationIgnored private var toastDismiss: Task<Void, Never>?
    @ObservationIgnored private var inboxDrain: Task<Void, Never>?

    init(container: ModelContainer) {
        self.container = container
        let context = container.mainContext
        importer = Importer(context: context)
        analysis = AnalysisQueue(context: context)
        sync = SyncEngine(context: context)

        importer.onAdded = { [weak self] item in
            self?.analysis.enqueue(item)
            self?.scheduleSync()
        }
        analysis.onItemAnalyzed = { [weak self] in self?.scheduleSync() }
        sync.onMediaDownloaded = { [weak self] item in self?.analysis.enqueue(item) }
    }

    var context: ModelContext { container.mainContext }

    func start() {
        analysis.resumeUnfinished()
        becameActive()
    }

    /// Foreground: file anything sent from the share sheet, then sync.
    func becameActive() {
        guard inboxDrain == nil else { return }
        inboxDrain = Task {
            let outcome = await importer.drainShareInbox()
            report(outcome)
            sync.requestSync()
            inboxDrain = nil
        }
    }

    func item(_ id: UUID?) -> StashItem? {
        guard let id else { return nil }
        var descriptor = FetchDescriptor<StashItem>(predicate: #Predicate { $0.id == id && !$0.pendingDeletion })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    // MARK: Import

    func paste(_ providers: [NSItemProvider]) {
        perform(progress: String(localized: "Adding…")) { try await self.importer.importFromPasteboard(providers) }
    }

    /// Keyboard ⌘V / Edit ▸ Paste.
    func paste(_ contents: [PastedContent]) {
        perform(progress: String(localized: "Adding…")) {
            var outcome = Importer.Outcome()
            var lastError: Error?
            for content in contents {
                do {
                    outcome.merge(try await self.importer.importIncoming(content.incoming))
                } catch {
                    lastError = error
                }
            }
            if outcome.added.isEmpty, outcome.duplicates.isEmpty, let lastError { throw lastError }
            return outcome
        }
    }

    func importData(_ data: [Data]) {
        perform(progress: String(localized: "Adding…")) {
            var outcome = Importer.Outcome()
            for blob in data {
                outcome.merge(try self.importer.importData(blob))
            }
            return outcome
        }
    }

    /// Used by the Add Link sheet, which shows its own progress and errors.
    func importLink(_ url: URL) async throws {
        let outcome = try await importer.importURL(url)
        report(outcome)
    }

    private func perform(progress: String, _ work: @escaping () async throws -> Importer.Outcome) {
        show(Toast(message: progress, systemImage: "arrow.down.circle", isProgress: true), autoDismiss: false)
        Task {
            do {
                report(try await work())
            } catch {
                toast = nil
                errorMessage = error.localizedDescription
            }
        }
    }

    private func report(_ outcome: Importer.Outcome) {
        if let first = outcome.added.first {
            let message = outcome.added.count == 1
                ? (first.isAnimated ? String(localized: "GIF added") : String(localized: "Image added"))
                : String(localized: "\(outcome.added.count) items added")
            show(Toast(message: message, systemImage: "checkmark.circle.fill", itemID: first.id))
        } else if let duplicate = outcome.duplicates.first {
            show(Toast(message: String(localized: "Already in your Stash"), systemImage: "square.on.square", itemID: duplicate.id))
        }
    }

    // MARK: Item actions

    func edited(_ item: StashItem) {
        item.touch()
        scheduleSync()
    }

    func copy(_ item: StashItem) {
        do {
            let data = try MediaStore.shared.read(id: item.id, type: item.contentType)
            // Supplying the original type keeps GIFs animated when pasted into Messages.
            UIPasteboard.general.setItems([[item.contentType.identifier: data]])
            item.lastUsedAt = .now
            try? context.save()
            show(Toast(message: String(localized: "Copied"), systemImage: "doc.on.doc.fill"))
        } catch {
            errorMessage = String(localized: "The file isn’t on this device yet. Try again after it syncs.")
        }
    }

    func toggleFavorite(_ item: StashItem) {
        item.isFavorite.toggle()
        edited(item)
    }

    func reanalyze(_ item: StashItem) {
        analysis.enqueue(item)
    }

    func delete(_ item: StashItem) {
        if selection == item.id { selection = nil }
        if sync.configuration != nil {
            item.pendingDeletion = true
            item.touch()
            scheduleSync(delay: .milliseconds(300))
        } else {
            MediaStore.shared.delete(id: item.id, type: item.contentType)
            context.delete(item)
        }
        try? context.save()
    }

    func search(for text: String) {
        searchText = text
        selection = nil
    }

    // MARK: Sync & toasts

    func scheduleSync(delay: Duration = .seconds(2)) {
        try? context.save()
        syncDebounce?.cancel()
        syncDebounce = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            sync.requestSync()
        }
    }

    func show(_ toast: Toast, autoDismiss: Bool = true) {
        self.toast = toast
        toastDismiss?.cancel()
        guard autoDismiss else { return }
        toastDismiss = Task {
            try? await Task.sleep(for: .seconds(2.4))
            guard !Task.isCancelled, self.toast?.id == toast.id else { return }
            self.toast = nil
        }
    }
}

enum LibraryFilter: String, CaseIterable, Identifiable {
    case all, animated, stills, favorites
    var id: Self { self }

    var title: String {
        switch self {
        case .all: String(localized: "All Items")
        case .animated: String(localized: "GIFs")
        case .stills: String(localized: "Images")
        case .favorites: String(localized: "Favorites")
        }
    }

    var systemImage: String {
        switch self {
        case .all: "square.grid.2x2"
        case .animated: "play.square.stack"
        case .stills: "photo"
        case .favorites: "heart"
        }
    }

    func includes(_ item: StashItem) -> Bool {
        switch self {
        case .all: true
        case .animated: item.isAnimated
        case .stills: !item.isAnimated
        case .favorites: item.isFavorite
        }
    }
}

enum LibrarySort: String, CaseIterable, Identifiable {
    case newest, recentlyUsed, oldest
    var id: Self { self }

    var title: String {
        switch self {
        case .newest: String(localized: "Recently Added")
        case .recentlyUsed: String(localized: "Recently Copied")
        case .oldest: String(localized: "Oldest First")
        }
    }
}
