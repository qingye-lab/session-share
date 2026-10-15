import AppKit
import ServiceManagement
import SwiftUI
@preconcurrency import UserNotifications

let claudeBundleID = "com.anthropic.claudefordesktop"

@MainActor
final class AppModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case confirmMerge
        case confirmUndo
        case working(String)
        case done(String)
        case failed(String)
    }

    enum Tab: Hashable { case desktop, terminal }

    @Published var snapshot: Snapshot?
    @Published var loadError: String?
    @Published var loading = false
    @Published var phase: Phase = .idle
    @Published var claudeRunning = false
    @Published var tab: Tab = .desktop
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled

    private var timer: Timer?

    init() {
        claudeRunning = Self.isClaudeRunning()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier == claudeBundleID else { return }
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.claudeRunning = Self.isClaudeRunning()
                    if !self.busy { Task { await self.refresh() } }
                }
            }
        }
        // keeps the menu bar badge current
        timer = Timer.scheduledTimer(withTimeInterval: 10 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.busy else { return }
                Task { await self.refresh() }
            }
        }
        Task { await refresh() }
    }

    var busy: Bool {
        if case .working = phase { return true }
        return false
    }

    var pending: Bool { (snapshot?.changes ?? 0) > 0 }

    // MARK: reading

    func refresh() async {
        loading = true
        defer { loading = false }
        claudeRunning = Self.isClaudeRunning()
        do {
            snapshot = try await Engine.state()
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Called when the panel opens: a stale result or confirmation is cleared.
    func panelOpened() {
        switch phase {
        case .done, .failed, .confirmMerge, .confirmUndo: phase = .idle
        default: break
        }
        Task { await refresh() }
    }

    // MARK: settings

    func setProject(_ path: String, on: Bool) {
        if let i = snapshot?.projects.firstIndex(where: { $0.path == path }) { snapshot?.projects[i].on = on }
        save(["set", "desktop", path, on ? "on" : "off"])
    }

    func setTerminal(_ path: String, on: Bool) {
        if let i = snapshot?.terminal.firstIndex(where: { $0.path == path }) { snapshot?.terminal[i].on = on }
        save(["set", "terminal", path, on ? "on" : "off"])
    }

    func setRemark(_ uuid: String, _ remark: String) {
        save(["remark", uuid, remark.trimmingCharacters(in: .whitespacesAndNewlines)])
    }

    private func save(_ args: [String]) {
        Task {
            do {
                _ = try await Engine.run(args)
            } catch {
                phase = .failed(error.localizedDescription)
            }
            await refresh()
        }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            phase = .failed("没能设置登录时启动：\(error.localizedDescription)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: merging

    func mergeTapped() {
        if claudeRunning { phase = .confirmMerge } else { Task { await merge() } }
    }

    func undoTapped() { phase = .confirmUndo }

    func cancel() { phase = .idle }

    func merge() async {
        await withClaudeClosed(verb: "合并", args: ["sync-all"])
    }

    func undo() async {
        await withClaudeClosed(verb: "撤销", args: ["undo"])
    }

    /// Quits Claude, runs the engine, opens Claude again.
    private func withClaudeClosed(verb: String, args: [String]) async {
        let wasRunning = Self.isClaudeRunning()
        if wasRunning {
            phase = .working("正在关闭 Claude…")
            guard await quitClaude() else {
                phase = .failed("Claude 没有退出（可能在等你确认），没有改动任何文件。")
                return
            }
        }
        phase = .working(verb == "合并" ? "正在合并会话…" : "正在撤销上次合并…")
        do {
            let message = try await Engine.run(args)
            phase = .working("正在打开 Claude…")
            openClaude()
            phase = .done(message)
            notify(title: "\(verb)完成", body: message)
        } catch {
            if wasRunning { openClaude() }
            phase = .failed("\(verb)失败：\(error.localizedDescription)")
        }
        await refresh()
    }

    func openClaude() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: claudeBundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    func revealBackups() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/session-share/backups")
        if FileManager.default.fileExists(atPath: dir.path) {
            NSWorkspace.shared.activateFileViewerSelecting([dir])
        } else {
            phase = .failed("还没有备份：第一次合并时才会创建。")
        }
    }

    // MARK: Claude

    static func isClaudeRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: claudeBundleID).isEmpty
    }

    /// Asks Claude to quit the way ⌘Q does, and waits up to 30 seconds.
    private func quitClaude() async -> Bool {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: claudeBundleID) { app.terminate() }
        for _ in 0..<60 {
            try? await Task.sleep(for: .milliseconds(500))
            if !Self.isClaudeRunning() {
                // let it finish writing its files
                try? await Task.sleep(for: .seconds(1))
                return true
            }
        }
        return false
    }

    private func notify(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}
