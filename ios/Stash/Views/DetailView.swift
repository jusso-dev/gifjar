import SwiftData
import SwiftUI

struct DetailView: View {
    @Environment(AppModel.self) private var model
    @Query private var matches: [StashItem]
    var showsMedia = true

    init(id: UUID, showsMedia: Bool = true) {
        _matches = Query(filter: #Predicate<StashItem> { $0.id == id && !$0.pendingDeletion })
        self.showsMedia = showsMedia
    }

    var body: some View {
        if let item = matches.first {
            DetailForm(item: item, showsMedia: showsMedia)
        } else {
            ContentUnavailableView("Item Deleted", systemImage: "trash", description: Text("This item is no longer in your Stash."))
        }
    }
}

private struct DetailForm: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Bindable var item: StashItem
    let showsMedia: Bool

    @State private var newPhrase = ""
    @State private var confirmingDelete = false
    @FocusState private var focus: Field?

    private enum Field { case title, phrase, notes }

    var body: some View {
        Form {
            if showsMedia {
                Section {
                    MediaPlayerView(item: item, fill: false)
                        .aspectRatio(item.aspectRatio, contentMode: .fit)
                        .frame(maxHeight: 420)
                        .frame(maxWidth: .infinity)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.black)
                }
            }

            Section {
                TextField("Title", text: $item.title, prompt: Text(item.aiSummary.isEmpty ? "Add a title" : item.displayTitle))
                    .font(.headline)
                    .focused($focus, equals: .title)
                    .submitLabel(.done)
            }

            Section {
                ForEach(item.phrases, id: \.self) { phrase in
                    Text(phrase)
                        .swipeActions {
                            Button("Delete", systemImage: "trash", role: .destructive) { removePhrase(phrase) }
                        }
                }
                .onDelete { offsets in
                    item.phrases.remove(atOffsets: offsets)
                    model.edited(item)
                }
                HStack {
                    TextField("Add a phrase", text: $newPhrase)
                        .focused($focus, equals: .phrase)
                        .submitLabel(.done)
                        .onSubmit(addPhrase)
                    if !newPhrase.trimmed.isEmpty {
                        Button("Add", systemImage: "plus.circle.fill", action: addPhrase)
                            .labelStyle(.iconOnly)
                    }
                }
            } header: {
                Text("Phrases")
            } footer: {
                Text("What you’d type to find this again, like “deal with it” or “monday mood”.")
            }

            Section("Notes") {
                TextField("Add notes", text: $item.notes, axis: .vertical)
                    .lineLimit(3...12)
                    .focused($focus, equals: .notes)
            }

            intelligenceSection
            infoSection

            Section {
                Button("Delete", systemImage: "trash", role: .destructive) { confirmingDelete = true }
            }
        }
        .navigationTitle(item.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .toolbar { toolbar }
        .onChange(of: focus) { old, _ in
            // Commit edits when a field loses focus rather than on every keystroke.
            if old != nil { model.edited(item) }
        }
        .onDisappear {
            if focus != nil { model.edited(item) }
        }
        .confirmationDialog("Delete this item?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                model.delete(item)
                dismiss()
            }
        } message: {
            Text("It will be removed from all your devices.")
        }
    }

    @ViewBuilder private var intelligenceSection: some View {
        Section {
            switch item.analysisState {
            case .pending, .analyzing:
                Label {
                    Text("Describing with Apple Intelligence…")
                } icon: {
                    ProgressView()
                }
                .foregroundStyle(.secondary)
            case .failed:
                Label("Couldn’t describe this image.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            case .done:
                if !item.aiSummary.isEmpty {
                    Text(item.aiSummary)
                }
                if !item.aiTags.isEmpty {
                    TagCloud(tags: item.aiTags) { tag in model.search(for: tag) }
                }
                if !item.ocrText.isEmpty {
                    LabeledContent("Text in Image") {
                        Text(item.ocrText).textSelection(.enabled)
                    }
                }
            }
        } header: {
            Label("Apple Intelligence", systemImage: "apple.intelligence")
        } footer: {
            if item.analysisState == .done || item.analysisState == .failed {
                Button("Describe Again") { model.reanalyze(item) }
                    .font(.footnote)
            }
        }
    }

    private var infoSection: some View {
        Section("Info") {
            LabeledContent("Kind", value: item.kindLabel)
            LabeledContent("Dimensions", value: "\(item.pixelWidth) × \(item.pixelHeight)")
            if item.isAnimated {
                LabeledContent("Frames", value: "\(item.frameCount)")
                LabeledContent("Length", value: Duration.seconds(item.duration).formatted(.units(allowed: [.seconds, .milliseconds], width: .abbreviated, maximumUnitCount: 2)))
            }
            LabeledContent("Size", value: Int64(item.byteCount).formatted(.byteCount(style: .file)))
            LabeledContent("Added", value: item.createdAt.formatted(date: .abbreviated, time: .shortened))
            if let source = item.sourceURL, let url = URL(string: source) {
                LabeledContent("Source") {
                    Link(url.host() ?? source, destination: url)
                        .lineLimit(1)
                }
            }
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button(item.isFavorite ? "Unfavorite" : "Favorite", systemImage: item.isFavorite ? "heart.fill" : "heart") {
                model.toggleFavorite(item)
            }
            .symbolEffect(.bounce, value: item.isFavorite)
            ShareLink(item: item.fileURL)
        }
        ToolbarItem(placement: .bottomBar) {
            Button {
                model.copy(item)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
        }
    }

    private func addPhrase() {
        let phrase = newPhrase.trimmed
        newPhrase = ""
        guard !phrase.isEmpty, !item.phrases.contains(where: { $0.caseInsensitiveCompare(phrase) == .orderedSame }) else { return }
        withAnimation { item.phrases.append(phrase) }
        model.edited(item)
        focus = .phrase
    }

    private func removePhrase(_ phrase: String) {
        withAnimation { item.phrases.removeAll { $0 == phrase } }
        model.edited(item)
    }
}

/// Shows the item large and playing, with a tap-to-pause control.
struct MediaPlayerView: View {
    let item: StashItem
    var fill: Bool
    @State private var isPaused = false
    @Environment(\.accessibilityPlayAnimatedImages) private var systemAllowsAnimation

    var body: some View {
        GeometryReader { geo in
            if MediaStore.shared.exists(id: item.id, type: item.contentType) {
                AnimatedImage(
                    url: item.fileURL,
                    maxPixelSize: max(geo.size.width, geo.size.height),
                    contentMode: fill ? .scaleAspectFill : .scaleAspectFit,
                    isPlaying: !isPaused
                )
            } else {
                ProgressView("Downloading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if item.isAnimated && systemAllowsAnimation {
                Button(isPaused ? "Play" : "Pause", systemImage: isPaused ? "play.fill" : "pause.fill") {
                    isPaused.toggle()
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .padding(12)
                .contentTransition(.symbolEffect(.replace))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(item.aiSummary.isEmpty ? item.displayTitle : item.aiSummary))
        .accessibilityAddTraits(.isImage)
    }
}

/// Wrapping row of tappable tags; tapping one searches for it.
struct TagCloud: View {
    let tags: [String]
    var onTap: (String) -> Void

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(tags, id: \.self) { tag in
                Button(tag) { onTap(tag) }
                    .font(.subheadline)
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                    .accessibilityHint(Text("Search for \(tag)"))
            }
        }
        .padding(.vertical, 4)
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: rows.last.map { $0.y + $0.height } ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0; var y: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if rows[rows.count - 1].width + size.width > width, !rows[rows.count - 1].indices.isEmpty {
                let last = rows[rows.count - 1]
                rows.append(Row(y: last.y + last.height + spacing))
            }
            rows[rows.count - 1].indices.append(index)
            rows[rows.count - 1].width += size.width + spacing
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
        }
        return rows
    }
}
