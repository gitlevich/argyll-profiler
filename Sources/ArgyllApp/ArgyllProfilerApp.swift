import SwiftUI
import ArgyllKit

@main
struct ArgyllProfilerApp: App {
    @StateObject private var model: RunModel

    init() {
        let model = RunModel()
        model.configure(arguments: CommandLine.arguments)
        _model = StateObject(wrappedValue: model)
    }

    var body: some Scene {
        WindowGroup("Argyll Profiler") {
            RootView()
                .environmentObject(model)
        }
        .windowResizability(.contentSize)
    }
}
