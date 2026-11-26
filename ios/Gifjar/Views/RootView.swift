import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Chooses a layout for the current display and hinge posture.
///
/// iPhone Duo:
/// - Folded (cover display): single column; detail pushes.
/// - Unfolded flat (inner display): library and detail side by side.
/// - Half-open ("tabletop"/"book"): a viewer pane and the library on either side
///   of the crease, with nothing interactive placed across the fold.
/// Every other iPhone gets the single column (or side by side in wide landscape).
struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var isHalfOpen = false

    /// Width at which two panes are comfortable (inner display, Max phones in landscape).
    private static let dualPaneMinWidth: CGFloat = 600

    var body: some View {
        @Bindable var model = model
        GeometryReader { geo in
            Group {
                if isHalfOpen {
                    HalfOpenLayout(size: geo.size)
                } else if geo.size.width >= Self.dualPaneMinWidth {
                    DualPaneLayout(width: geo.size.width)
                } else {
                    CompactLayout()
                }
            }
            .animation(.smooth, value: isHalfOpen)
        }
        .modifier(HingeObserver(isHalfOpen: $isHalfOpen))
        .overlay(alignment: .bottom) { ToastView() }
        .pasteDestination(for: PastedContent.self) { model.paste($0) }
        .onDrop(of: Importer.pasteTypes, isTargeted: nil) { providers in
            model.paste(providers)
            return true
        }
        .sheet(isPresented: $model.showingAddLink) { AddLinkView() }
        .sheet(isPresented: $model.showingSettings) { SettingsView() }
        .alert(
            "Couldn’t Add Item",
            isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } }),
            presenting: model.errorMessage
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { Text($0) }
    }
}

/// Tracks the iPhone Duo hinge (iOS 27.1+). Other devices never report a hinge.
private struct HingeObserver: ViewModifier {
    @Binding var isHalfOpen: Bool

    func body(content: Content) -> some View {
        if #available(iOS 27.1, *) {
            content.onHingeChange { _, new in
                isHalfOpen = new.hinge?.status == .partiallyOpen
            }
        } else {
            content
        }
    }
}

// MARK: - Folded / regular iPhone

private struct CompactLayout: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack(path: selectionPath) {
            LibraryView()
                .navigationDestination(for: UUID.self) { id in
                    DetailView(id: id)
                }
        }
    }

    private var selectionPath: Binding<[UUID]> {
        Binding(
            get: { model.selection.map { [$0] } ?? [] },
            set: { model.selection = $0.last }
        )
    }
}

// MARK: - Unfolded flat

private struct DualPaneLayout: View {
    @Environment(AppModel.self) private var model
    let width: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            NavigationStack {
                LibraryView()
            }
            .frame(maxWidth: .infinity)

            if let id = model.selection {
                Divider().ignoresSafeArea()
                NavigationStack {
                    DetailView(id: id)
                }
                // An inspector-style pane: enough room for the player and the form.
                .frame(width: min(max(width * 0.46, 320), 460))
                .transition(.move(edge: .trailing))
                .id(id)
            }
        }
        .animation(.smooth(duration: 0.3), value: model.selection)
    }
}

// MARK: - Half-open (tabletop / book)

private struct HalfOpenLayout: View {
    @Environment(AppModel.self) private var model
    @Query(filter: #Predicate<GifjarItem> { !$0.pendingDeletion }, sort: \GifjarItem.createdAt, order: .reverse)
    private var items: [GifjarItem]
    let size: CGSize

    /// Clear space either side of the crease.
    private let creaseGutter: CGFloat = 28

    var body: some View {
        let stacked = size.height >= size.width
        let layout = stacked
            ? AnyLayout(VStackLayout(spacing: creaseGutter))
            : AnyLayout(HStackLayout(spacing: creaseGutter))

        layout {
            ViewerPane(item: model.item(model.selection) ?? items.first)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            NavigationStack {
                LibraryView(isEmbeddedBrowser: true)
                    .navigationDestination(for: UUID.self) { id in
                        DetailView(id: id, showsMedia: false)
                    }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(.systemGroupedBackground))
    }
}

/// The "screen" half of tabletop mode: the selected item, large and playing.
private struct ViewerPane: View {
    @Environment(AppModel.self) private var model
    let item: GifjarItem?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea(edges: [.top, .horizontal])
            if let item {
                MediaPlayerView(item: item, fill: false)
                    .overlay(alignment: .bottomLeading) {
                        HStack(spacing: 12) {
                            Text(item.displayTitle)
                                .font(.headline)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Button("Copy", systemImage: "doc.on.doc") { model.copy(item) }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.glass)
                        }
                        .padding(.leading, 16)
                        .padding(8)
                        .glassEffect(.regular, in: .capsule)
                        .padding()
                    }
            } else {
                ContentUnavailableView("Nothing Selected", systemImage: "photo.on.rectangle", description: Text("Choose something from your Gifjar to view it here."))
                    .foregroundStyle(.white)
            }
        }
    }
}
