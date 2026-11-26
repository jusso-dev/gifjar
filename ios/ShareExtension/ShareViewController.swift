import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Share sheet entry point: "Save to Gifjar" from Photos, Safari, Messages, GIPHY, Tenor, etc.
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            .flatMap { $0.attachments ?? [] }
        let model = ShareModel(providers: providers) { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        } cancel: { [weak self] in
            self?.extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
        }
        let host = UIHostingController(rootView: ShareView(model: model))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        model.load()
    }
}

@Observable
final class ShareModel {
    enum Phase: Equatable {
        case loading
        /// Image bytes in hand; preview from a temp file so GIFs animate.
        case ready(previewURL: URL, isAnimated: Bool, count: Int)
        /// A link we couldn't fetch right now; the app will retry it.
        case deferredLink(URL)
        case failed(String)
    }

    var phase: Phase = .loading
    var title = ""
    var phrase = ""
    var isSaving = false
    var saveError: String?

    private let providers: [NSItemProvider]
    private let finish: () -> Void
    private let cancelAction: () -> Void
    private var media: [ResolvedMedia] = []

    init(providers: [NSItemProvider], finish: @escaping () -> Void, cancel: @escaping () -> Void) {
        self.providers = providers
        self.finish = finish
        self.cancelAction = cancel
    }

    func load() {
        Task {
            do {
                switch try await collectIncoming() {
                case .images(let blobs):
                    let resolved = blobs.compactMap { try? MediaResolver.media($0) }
                    guard !resolved.isEmpty else { throw ImportError.notAnImage }
                    show(resolved)
                case .link(let url):
                    do {
                        show([try await MediaResolver.resolve(url)])
                    } catch let error as ImportError where error.isPermanent {
                        throw error
                    } catch {
                        phase = .deferredLink(url)
                    }
                }
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private enum Collected {
        case images([Data])
        case link(URL)
    }

    /// Image bytes win over links: Safari shares both the page URL and, for a long-pressed image, the image.
    private func collectIncoming() async throws -> Collected {
        var images: [Data] = []
        var link: URL?
        var lastError: Error = ImportError.nothingToImport
        for provider in providers {
            do {
                switch try await MediaResolver.incoming(from: provider) {
                case .media(let data): images.append(data)
                case .link(let url): link = link ?? url
                }
            } catch {
                lastError = error
            }
        }
        if !images.isEmpty { return .images(images) }
        if let link { return .link(link) }
        throw lastError
    }

    private func show(_ resolved: [ResolvedMedia]) {
        guard let first = resolved.first else { return }
        media = resolved
        if title.isEmpty, let suggested = first.suggestedTitle { title = suggested }
        let ext = first.type.preferredFilenameExtension ?? "img"
        let url = FileManager.default.temporaryDirectory.appending(path: "share-preview-\(UUID().uuidString).\(ext)")
        try? first.data.write(to: url, options: .atomic)
        phase = .ready(previewURL: url, isAnimated: first.info.frameCount > 1, count: resolved.count)
    }

    var canSave: Bool {
        switch phase {
        case .ready, .deferredLink: !isSaving
        default: false
        }
    }

    func save() {
        guard let inbox = ShareInbox.shared else {
            saveError = String(localized: "Open Gifjar once, then try again.")
            return
        }
        isSaving = true
        var request = ShareRequest(title: title.trimmed, phrase: phrase.trimmed)
        do {
            switch phase {
            case .ready:
                for item in media {
                    var each = request
                    each.id = UUID()
                    each.sourceURL = item.sourceURL
                    try inbox.enqueue(each, media: item.data, type: item.type)
                }
            case .deferredLink(let url):
                request.link = url
                try inbox.enqueue(request)
            default:
                return
            }
            finish()
        } catch {
            isSaving = false
            saveError = error.localizedDescription
        }
    }

    func cancel() { cancelAction() }
}

struct ShareView: View {
    @Bindable var model: ShareModel
    @FocusState private var phraseFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    preview
                        .frame(maxWidth: .infinity)
                        .frame(height: 240)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }

                if model.canSave || model.isSaving {
                    Section {
                        TextField("Title", text: $model.title)
                            .submitLabel(.next)
                            .onSubmit { phraseFocused = true }
                        TextField("Phrase, like “mind blown”", text: $model.phrase)
                            .focused($phraseFocused)
                            .submitLabel(.done)
                            .onSubmit(model.save)
                    } footer: {
                        if let error = model.saveError {
                            Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red)
                        } else {
                            Text("Apple Intelligence describes it when you next open Gifjar, so you can search for it later.")
                        }
                    }
                }
            }
            .navigationTitle("Save to Gifjar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel, action: model.cancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if model.isSaving {
                        ProgressView()
                    } else {
                        Button("Save", role: .confirm, action: model.save)
                            .disabled(!model.canSave)
                    }
                }
            }
        }
    }

    @ViewBuilder private var preview: some View {
        switch model.phase {
        case .loading:
            ProgressView("Finding the image…")
        case .ready(let url, let isAnimated, let count):
            AnimatedImage(url: url, maxPixelSize: 480, contentMode: .scaleAspectFit)
                .clipShape(.rect(cornerRadius: 12))
                .overlay(alignment: .bottomLeading) {
                    if isAnimated {
                        Text("GIF")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(.black.opacity(0.55), in: .rect(cornerRadius: 4))
                            .foregroundStyle(.white)
                            .padding(8)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if count > 1 {
                        Text("+\(count - 1)")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .glassEffect()
                            .padding(8)
                            .accessibilityLabel("\(count) items")
                    }
                }
                .accessibilityLabel(isAnimated ? "Animated GIF preview" : "Image preview")
        case .deferredLink(let url):
            ContentUnavailableView {
                Label(url.host() ?? "Link", systemImage: "link")
            } description: {
                Text("Couldn’t load this page right now. Gifjar will fetch the image when you next open it.")
            }
        case .failed(let message):
            ContentUnavailableView("Can’t Save This", systemImage: "photo.badge.exclamationmark", description: Text(message))
        }
    }
}
