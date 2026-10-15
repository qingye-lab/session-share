import SwiftUI

// Development only: SESSION_MERGE_PREVIEW=<png> renders the panel to a file
// and quits. SESSION_MERGE_PREVIEW_LOOK=dark, SESSION_MERGE_PREVIEW_PHASE=
// confirmMerge|confirmUndo|working|done|failed|loadError and SESSION_MERGE_PREVIEW_TAB=
// terminal pick what it shows. SESSION_MERGE_PREVIEW_DATA=empty|synced exercises
// empty and up-to-date states without changing the demo data.
@MainActor
enum Preview {
    static var model: AppModel?
    static var window: NSWindow?

    static func runIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard let out = env["SESSION_MERGE_PREVIEW"] else { return }
        NSApp.appearance = NSAppearance(named: env["SESSION_MERGE_PREVIEW_LOOK"] == "dark" ? .darkAqua : .aqua)
        let model = AppModel()
        self.model = model
        Task { @MainActor in
            for _ in 0..<100 where model.snapshot == nil && model.loadError == nil {
                try? await Task.sleep(for: .milliseconds(200))
            }
            let look = NSAppearance(named: env["SESSION_MERGE_PREVIEW_LOOK"] == "dark" ? .darkAqua : .aqua)
            let root = PanelView(refreshOnAppear: false).environmentObject(model)
                .background(Color(nsColor: .windowBackgroundColor))
                .ignoresSafeArea()
            let host = NSHostingView(rootView: root)
            host.appearance = look
            let w = NSWindow(contentRect: NSRect(x: 200, y: 200, width: Brand.panelWidth, height: 700),
                             styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.backgroundColor = .windowBackgroundColor
            w.appearance = look
            w.contentView = host
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            window = w
            try? await Task.sleep(for: .milliseconds(1500))
            if env["SESSION_MERGE_PREVIEW_TAB"] == "terminal" { model.tab = .terminal }
            if env["SESSION_MERGE_PREVIEW_DATA"] == "empty", var snapshot = model.snapshot {
                snapshot.accounts = []
                snapshot.projects = []
                snapshot.terminal = []
                snapshot.sessions = 0
                snapshot.changes = 0
                model.snapshot = snapshot
            }
            if env["SESSION_MERGE_PREVIEW_DATA"] == "synced", var snapshot = model.snapshot {
                snapshot.changes = 0
                snapshot.imports = 0
                for i in snapshot.accounts.indices {
                    snapshot.accounts[i].have = snapshot.sessions
                    snapshot.accounts[i].add = 0
                    snapshot.accounts[i].update = 0
                    snapshot.accounts[i].remove = 0
                }
                model.snapshot = snapshot
            }
            switch env["SESSION_MERGE_PREVIEW_PHASE"] {
            case "confirmMerge": model.phase = .confirmMerge
            case "confirmUndo": model.phase = .confirmUndo
            case "working": model.phase = .working("正在合并会话…")
            case "done": model.phase = .done("3 个账号都能看到 39 个会话（写入 98 处，导入 9 个终端会话）")
            case "failed": model.phase = .failed("Claude 没有退出（可能在等你确认），没有改动任何文件。")
            case "loadError":
                model.snapshot = nil
                model.loadError = "暂时无法读取本机会话，请重新读取。"
            default: break
            }
            try? await Task.sleep(for: .milliseconds(600))
            w.setContentSize(host.fittingSize)
            try? await Task.sleep(for: .milliseconds(400))
            let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
            exit(0)
        }
    }
}
