import SwiftData
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Query private var items: [StashItem]
    @AppStorage("autoplayInLibrary") private var autoplay = true

    @State private var token = ""
    @State private var testState: TestState = .idle

    private enum TestState: Equatable { case idle, testing, ok, failed(String) }

    var body: some View {
        @Bindable var sync = model.sync
        NavigationStack {
            Form {
                Section {
                    TextField("Worker URL", text: $sync.serverURLString, prompt: Text("https://stash-api.example.workers.dev"))
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField(model.sync.hasToken ? "Token saved — enter to replace" : "Access token", text: $token)
                        .textContentType(.password)
                        .onSubmit(saveToken)
                    Button("Test Connection", action: test)
                        .disabled(sync.serverURLString.trimmed.isEmpty || (!model.sync.hasToken && token.isEmpty) || testState == .testing)
                    testResult
                } header: {
                    Text("Cloud Storage")
                } footer: {
                    Text("Originals and notes sync to your Cloudflare R2 bucket through your Worker. The token is kept in the Keychain on this device.")
                }

                Section("Status") {
                    LabeledContent("Sync", value: statusText)
                    if let last = model.sync.lastSynced {
                        LabeledContent("Last Synced") { Text(last, style: .relative) }
                    }
                    Button("Sync Now") { model.sync.requestSync() }
                        .disabled(model.sync.configuration == nil || model.sync.status == .syncing)
                    if model.sync.hasToken {
                        Button("Disconnect", role: .destructive) {
                            model.sync.disconnect()
                            testState = .idle
                        }
                    }
                }

                Section {
                    LabeledContent("Status", value: intelligenceText)
                    let waiting = items.filter { $0.analysisState == .pending || $0.analysisState == .analyzing }.count
                    if waiting > 0 {
                        LabeledContent("Waiting to Describe", value: "\(waiting)")
                    }
                } header: {
                    Text("Apple Intelligence")
                } footer: {
                    Text("Descriptions, tags, and text recognition run on this iPhone. Images aren’t sent anywhere for analysis.")
                }

                Section("Library") {
                    Toggle("Autoplay GIFs in Library", isOn: $autoplay)
                    LabeledContent("Items", value: "\(items.filter { !$0.pendingDeletion }.count)")
                    LabeledContent("Storage Used", value: Int64(items.reduce(0) { $0 + $1.byteCount }).formatted(.byteCount(style: .file)))
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", role: .confirm) {
                        saveToken()
                        model.sync.requestSync()
                        dismiss()
                    }
                }
            }
        }
    }

    @ViewBuilder private var testResult: some View {
        switch testState {
        case .idle: EmptyView()
        case .testing: Label { Text("Connecting…") } icon: { ProgressView() }
        case .ok: Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed(let message): Label(message, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
        }
    }

    private var statusText: String {
        switch model.sync.status {
        case .notConfigured: String(localized: "Not Set Up")
        case .idle: String(localized: "Up to Date")
        case .syncing: String(localized: "Syncing…")
        case .offline: String(localized: "Offline")
        case .failed(let message): message
        }
    }

    private var intelligenceText: String {
        switch ImageAnalyzer.modelStatus {
        case .availableWithVision: String(localized: "Ready")
        case .availableTextOnly: String(localized: "Ready (text clues only)")
        case .unavailable(let reason): reason
        }
    }

    private func saveToken() {
        guard !token.trimmed.isEmpty else { return }
        model.sync.updateToken(token)
        token = ""
    }

    private func test() {
        saveToken()
        testState = .testing
        Task {
            do {
                try await model.sync.testConnection()
                testState = .ok
                model.sync.requestSync()
            } catch {
                testState = .failed(error.localizedDescription)
            }
        }
    }
}

struct ToastView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let toast = model.toast {
            Button {
                if let id = toast.itemID { model.selection = id }
                model.toast = nil
            } label: {
                HStack(spacing: 10) {
                    if toast.isProgress {
                        ProgressView()
                    } else {
                        Image(systemName: toast.systemImage)
                            .foregroundStyle(.tint)
                    }
                    Text(toast.message)
                        .font(.subheadline.weight(.semibold))
                    if toast.itemID != nil {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .capsule)
            .padding(.bottom, 24)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .id(toast.id)
            .accessibilityAddTraits(.isStaticText)
            .onAppear {
                AccessibilityNotification.Announcement(toast.message).post()
            }
        }
    }
}
