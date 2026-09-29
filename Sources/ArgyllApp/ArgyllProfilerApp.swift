import SwiftUI
import AppKit
import ArgyllKit

/// Kills any running Argyll tool when the app quits; they run in their own session
/// and would otherwise keep measuring with nobody listening.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: RunModel?
    func applicationWillTerminate(_ notification: Notification) {
        model?.terminateChildren()
    }
}

@main
struct ArgyllProfilerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
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
                .onAppear { delegate.model = model }
        }
        .windowResizability(.contentSize)
    }
}
