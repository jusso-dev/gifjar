import PhotosUI
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @Query(filter: #Predicate<StashItem> { !$0.pendingDeletion }, sort: \StashItem.createdAt, order: .reverse)
    private var items: [StashItem]
    @AppStorage("autoplayInLibrary") private var autoplay = true
    @State private var photoSelection: [PhotosPickerItem] = []
    @State private var showingPhotoPicker = false
    @State private var pendingDelete: StashItem?

    /// In half-open mode the library is the browser under the viewer.
    var isEmbeddedBrowser = false

    var body: some View {
        @Bindable var model = model
        let results = filteredItems

        ScrollView {
            if !results.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: isEmbeddedBrowser ? 96 : 110), spacing: 2)], spacing: 2) {
                    ForEach(results) { item in
                        cell(for: item)
                    }
                }
                .padding(.bottom, 80)
            }
        }
        .overlay { emptyState(resultsEmpty: results.isEmpty) }
        .navigationTitle(model.filter == .all ? String(localized: "Stash") : model.filter.title)
        .toolbarTitleDisplayMode(isEmbeddedBrowser ? .inline : .large)
        .searchable(text: $model.searchText, prompt: "Phrases, notes, objects, text")
        .searchSuggestions { suggestions }
        .searchScopes($model.filter) {
            ForEach(LibraryFilter.allCases) { Text($0.title).tag($0) }
        }
        .toolbar { toolbarContent }
        .photosPicker(isPresented: $showingPhotoPicker, selection: $photoSelection, matching: .images, photoLibrary: .shared())
        .onChange(of: photoSelection) { _, picked in
            guard !picked.isEmpty else { return }
            Task {
                var blobs: [Data] = []
                for entry in picked {
                    if let data = try? await entry.loadTransferable(type: Data.self) { blobs.append(data) }
                }
                photoSelection = []
                model.importData(blobs)
            }
        }
        .confirmationDialog(
            "Delete this item?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { item in
            Button("Delete", role: .destructive) { model.delete(item) }
        } message: { _ in
            Text("It will be removed from all your devices.")
        }
    }

    // MARK: Grid cell

    private func cell(for item: StashItem) -> some View {
        Button {
            model.selection = item.id
        } label: {
            GridCell(item: item, autoplay: autoplay, isSelected: model.selection == item.id)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Copy", systemImage: "doc.on.doc") { model.copy(item) }
            ShareLink(item: item.fileURL) { Label("Share", systemImage: "square.and.arrow.up") }
            Button(item.isFavorite ? "Unfavorite" : "Favorite", systemImage: item.isFavorite ? "heart.slash" : "heart") {
                model.toggleFavorite(item)
            }
            Divider()
            Button("Delete", systemImage: "trash", role: .destructive) { pendingDelete = item }
        } preview: {
            MediaPlayerView(item: item, fill: false)
                .frame(width: 320, height: 320 / item.aspectRatio)
        }
        .accessibilityLabel(Text("\(item.displayTitle), \(item.kindLabel)"))
        .accessibilityHint(Text("Opens details"))
        .accessibilityAction(named: "Copy") { model.copy(item) }
        .accessibilityAction(named: item.isFavorite ? "Unfavorite" : "Favorite") { model.toggleFavorite(item) }
    }

    // MARK: Filtering & search

    private var filteredItems: [StashItem] {
        let scoped = items.filter { model.filter.includes($0) }
        let query = model.searchText.trimmed
        guard !query.isEmpty else { return sorted(scoped) }
        var ranked: [(item: StashItem, score: Double)] = []
        for item in scoped {
            if let score = SearchIndex.score(SearchIndex.fields(of: item), query: query) {
                ranked.append((item, score))
            }
        }
        ranked.sort { a, b in
            a.score == b.score ? a.item.createdAt > b.item.createdAt : a.score > b.score
        }
        return ranked.map(\.item)
    }

    private func sorted(_ list: [StashItem]) -> [StashItem] {
        switch model.sort {
        case .newest: list
        case .oldest: list.reversed()
        case .recentlyUsed: list.sorted { ($0.lastUsedAt ?? .distantPast) > ($1.lastUsedAt ?? .distantPast) }
        }
    }

    /// Most common phrases and tags, offered while the search field is empty or partially typed.
    @ViewBuilder private var suggestions: some View {
        let query = SearchIndex.normalize(model.searchText.trimmed)
        let all = items.flatMap { $0.phrases + $0.aiTags }
        let counts = Dictionary(all.map { ($0.lowercased(), 1) }, uniquingKeysWith: +)
        let ranked = counts
            .filter { query.isEmpty || SearchIndex.normalize($0.key).hasPrefix(query) && $0.key != query }
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(8)
        ForEach(ranked, id: \.key) { entry in
            Label(entry.key, systemImage: "magnifyingglass").searchCompletion(entry.key)
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Menu("Options", systemImage: "line.3.horizontal.decrease") {
                Picker("Sort", selection: Binding(get: { model.sort }, set: { model.sort = $0 })) {
                    ForEach(LibrarySort.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Autoplay GIFs", systemImage: "play.circle", isOn: $autoplay)
                Divider()
                Button("Settings", systemImage: "gear") { model.showingSettings = true }
            }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            if model.importer.isImporting {
                ProgressView().accessibilityLabel("Adding")
            }
            PasteButton(supportedContentTypes: Importer.pasteTypes) { providers in
                model.paste(providers)
            }
            .labelStyle(.iconOnly)
            .buttonBorderShape(.circle)

            Menu("Add", systemImage: "plus") {
                Button("Add from Link", systemImage: "link") { model.showingAddLink = true }
                Button("Choose from Photos", systemImage: "photo.on.rectangle") { showingPhotoPicker = true }
            }
        }
    }

    // MARK: Empty states

    @ViewBuilder private func emptyState(resultsEmpty: Bool) -> some View {
        if items.isEmpty {
            ContentUnavailableView {
                Label("Your Stash Is Empty", systemImage: "square.and.arrow.down.on.square")
            } description: {
                Text("Copy a GIF or image anywhere, then paste it here. Apple Intelligence describes it so you can search for it later.")
            } actions: {
                PasteButton(supportedContentTypes: Importer.pasteTypes) { model.paste($0) }
                    .buttonBorderShape(.capsule)
                Button("Add from Link") { model.showingAddLink = true }
            }
        } else if resultsEmpty, !model.searchText.isEmpty {
            ContentUnavailableView.search(text: model.searchText)
        } else if resultsEmpty {
            ContentUnavailableView(
                "No \(model.filter.title)",
                systemImage: model.filter.systemImage,
                description: Text(model.filter == .favorites ? "Items you favorite appear here." : "Nothing matches this filter yet.")
            )
        }
    }
}

// MARK: - Grid cell

private struct GridCell: View {
    let item: StashItem
    let autoplay: Bool
    let isSelected: Bool

    var body: some View {
        Color(.secondarySystemFill)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                GeometryReader { geo in
                    if MediaStore.shared.exists(id: item.id, type: item.contentType) {
                        AnimatedImage(url: item.fileURL, maxPixelSize: geo.size.width, isPlaying: autoplay)
                    } else {
                        Image(systemName: "icloud.and.arrow.down")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .clipped()
            .overlay(alignment: .bottomLeading) { badges }
            .overlay {
                if isSelected {
                    Rectangle().strokeBorder(.tint, lineWidth: 3)
                }
            }
            .contentShape(.rect)
    }

    private var badges: some View {
        HStack(spacing: 4) {
            if item.isAnimated {
                Text(item.isGIF ? "GIF" : "LIVE")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.55), in: .rect(cornerRadius: 4))
                    .foregroundStyle(.white)
            }
            if item.isFavorite {
                Image(systemName: "heart.fill")
                    .font(.caption2)
                    .foregroundStyle(.white)
                    .shadow(radius: 2)
            }
            if item.analysisState == .analyzing || item.analysisState == .pending {
                Image(systemName: "sparkles")
                    .font(.caption2)
                    .foregroundStyle(.white)
                    .shadow(radius: 2)
                    .symbolEffect(.pulse)
                    .accessibilityLabel("Analyzing")
            }
        }
        .padding(5)
    }
}
