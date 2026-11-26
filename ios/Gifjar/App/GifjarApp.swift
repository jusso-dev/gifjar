import SwiftData
import SwiftUI

@main
struct GifjarApp: App {
    @State private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let container: ModelContainer
        do {
            container = try ModelContainer(for: GifjarItem.self)
        } catch {
            // A schema we can't open is unrecoverable without data loss; fail loudly in development.
            fatalError("Could not open the Gifjar library: \(error)")
        }
        _model = State(initialValue: AppModel(container: container))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .modelContainer(model.container)
                .task { model.start() }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: model.becameActive()
            case .background: model.sync.requestSync()
            default: break
            }
        }
    }
}
