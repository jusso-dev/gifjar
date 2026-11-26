import PhotosUI
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @Query(filter: #Predicate<GifjarItem> { !$0.pendingDeletion }, sort: \GifjarItem.createdAt, order: .reverse)
    private var items: [GifjarItem]
    @AppStorage("autoplayInLibrary") private var autoplay = true
    @State private var photoSelection: [PhotosPickerItem] = []
    @State private var showingPhotoPicker = false
    @State private var pendingDelete: GifjarItem?
    /// Item showing the double-tap heart burst.
    @State private var heartBurst: UUID?

    /// In half-open mode the library is the browser under the viewer.
    var isEmbeddedBrowser = false

    var body: some View {
        @Bindable var model = model
        let results = filteredItems

        Group {
            if results.isEmpty {
                // Replaces the grid rather than overlaying an empty ScrollView, so the
                // message gets the full width on every display (incl. the Duo cover screen).
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    if showsFavoritesShelf {
                        FavoritesShelf(items: favorites) { model.filter = .favorites }
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: isEmbeddedBrowser ? 96 : 110), spacing: 2)], spacing: 2) {
                        ForEach(results) { item in
                            cell(for: item)
                        }
                    }
                    .padding(.bottom, 80)
                }
            }
        }
        .navigationTitle(model.filter == .all ? String(localized: "Gifjar") : model.filter.title)
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
        .sensoryFeedback(.impact(weight: .light), trigger: heartBurst) { _, new in new != nil }
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

    private func cell(for item: GifjarItem) -> some View {
        GridCell(item: item, autoplay: autoplay, isSelected: model.selection == item.id,
                 showsHeartBurst: heartBurst == item.id)
            // Double-tap to favourite, like Photos; a single tap still opens it.
            .onTapGesture(count: 2) { favoriteWithBurst(item) }
            .onTapGesture { model.selection = item.id }
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { model.selection = item.id }
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

    private func favoriteWithBurst(_ item: GifjarItem) {
        model.toggleFavorite(item)
        guard item.isFavorite else { return }
        withAnimation(.spring(duration: 0.3, bounce: 0.5)) { heartBurst = item.id }
        Task {
            try? await Task.sleep(for: .milliseconds(650))
            withAnimation(.easeOut(duration: 0.25)) { if heartBurst == item.id { heartBurst = nil } }
        }
    }

    // MARK: Favorites shelf

    /// Most-reused first, so the ones you send all the time sit at the front.
    private var favorites: [GifjarItem] {
        items.filter(\.isFavorite).sorted {
            ($0.lastUsedAt ?? $0.createdAt) > ($1.lastUsedAt ?? $1.createdAt)
        }
    }

    private var showsFavoritesShelf: Bool {
        model.filter == .all && model.searchText.trimmed.isEmpty && items.contains(where: \.isFavorite)
    }

    // MARK: Filtering & search

    private var filteredItems: [GifjarItem] {
        let scoped = items.filter { model.filter.includes($0) }
        let query = model.searchText.trimmed
        guard !query.isEmpty else { return sorted(scoped) }
        var ranked: [(item: GifjarItem, score: Double)] = []
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

    private func sorted(_ list: [GifjarItem]) -> [GifjarItem] {
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

    @ViewBuilder private var emptyState: some View {
        if items.isEmpty {
            ContentUnavailableView {
                Label("Gifjar Is Empty", systemImage: "square.and.arrow.down.on.square")
            } description: {
                Text("Copy a GIF or image anywhere, then paste it here. Apple Intelligence describes it so you can search for it later.")
            } actions: {
                PasteButton(supportedContentTypes: Importer.pasteTypes) { model.paste($0) }
                    .buttonBorderShape(.capsule)
                Button("Add from Link") { model.showingAddLink = true }
            }
        } else if !model.searchText.isEmpty {
            ContentUnavailableView.search(text: model.searchText)
        } else {
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
    let item: GifjarItem
    let autoplay: Bool
    let isSelected: Bool
    var showsHeartBurst = false

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
            .overlay {
                if showsHeartBurst {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 44, weight: .semibold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.35), radius: 6)
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                        .accessibilityHidden(true)
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

// MARK: - Favorites shelf

/// A row of favourites above the grid. One tap copies, ready to paste again.
private struct FavoritesShelf: View {
    @Environment(AppModel.self) private var model
    let items: [GifjarItem]
    let seeAll: () -> Void

    @ScaledMetric(relativeTo: .body) private var tile: CGFloat = 76

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Label("Favorites", systemImage: "heart.fill")
                    .font(.headline)
                    .labelStyle(.titleAndIcon)
                    .symbolRenderingMode(.multicolor)
                Spacer()
                Button("See All", action: seeAll)
                    .font(.subheadline)
            }
            .padding(.horizontal)

            ScrollView(.horizontal) {
                LazyHStack(spacing: 8) {
                    ForEach(items) { item in
                        Button {
                            model.copy(item)
                        } label: {
                            Color(.secondarySystemFill)
                                .frame(width: tile, height: tile)
                                .overlay {
                                    if MediaStore.shared.exists(id: item.id, type: item.contentType) {
                                        AnimatedImage(url: item.fileURL, maxPixelSize: tile)
                                    }
                                }
                                .clipShape(.rect(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Copy", systemImage: "doc.on.doc") { model.copy(item) }
                            Button("Show Details", systemImage: "info.circle") { model.selection = item.id }
                            ShareLink(item: item.fileURL) { Label("Share", systemImage: "square.and.arrow.up") }
                            Divider()
                            Button("Unfavorite", systemImage: "heart.slash") { model.toggleFavorite(item) }
                        } preview: {
                            MediaPlayerView(item: item, fill: false)
                                .frame(width: 320, height: 320 / item.aspectRatio)
                        }
                        .accessibilityLabel(Text("\(item.displayTitle), \(item.kindLabel)"))
                        .accessibilityHint(Text("Copies it so you can paste it anywhere"))
                    }
                }
                .padding(.horizontal)
            }
            .scrollIndicators(.hidden)
            .frame(height: tile)
        }
        .padding(.vertical, 12)
    }
}
