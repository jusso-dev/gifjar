import SwiftUI
import UIKit

/// Paste or type a link to a GIF, an image, or a page that has one (Giphy, Tenor, Imgur, articles…).
struct AddLinkView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var isWorking = false
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://", text: $text, axis: .vertical)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focused)
                        .submitLabel(.go)
                        .onSubmit(add)
                        .disabled(isWorking)
                } footer: {
                    if let error {
                        Label(error, systemImage: "exclamationmark.circle")
                            .foregroundStyle(.red)
                    } else {
                        Text("Gifjar downloads the image or GIF and finds it on web pages like GIPHY and Tenor.")
                    }
                }
            }
            .navigationTitle("Add from Link")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isWorking {
                        ProgressView()
                    } else {
                        Button("Add", role: .confirm, action: add)
                            .disabled(url == nil)
                    }
                }
            }
            .onAppear {
                // Prefill from the clipboard only if it already holds a link (no paste prompt for plain text).
                if text.isEmpty, UIPasteboard.general.hasURLs, let link = UIPasteboard.general.url {
                    text = link.absoluteString
                }
                focused = true
            }
        }
        .presentationDetents([.medium])
        .interactiveDismissDisabled(isWorking)
    }

    private var url: URL? {
        let raw = text.trimmed
        guard !raw.isEmpty else { return nil }
        if let found = LinkMetadata.firstURL(in: raw) { return found }
        return URL(string: raw.contains("://") ? raw : "https://\(raw)")
    }

    private func add() {
        guard let url, !isWorking else { return }
        isWorking = true
        error = nil
        Task {
            defer { isWorking = false }
            do {
                try await model.importLink(url)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
