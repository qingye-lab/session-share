import SwiftUI

// 会话合并: a menu bar app that makes every Claude desktop account's sidebar
// show every local Code session.
@main
struct SessionMergeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            PanelView().environmentObject(model)
        } label: {
            Image(systemName: model.pending ? "rectangle.stack.badge.plus" : "rectangle.stack")
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { Preview.runIfRequested() }
    }
}
