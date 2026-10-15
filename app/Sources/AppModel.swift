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
    @Published private(set) var saving = false
    @Published var phase: Phase = .idle
    @Published var claudeRunning = false
    @Published var tab: Tab = .desktop
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled

    private var timer: Timer?
    private var refreshTask: Task<Void, Never>?
    private var pendingSettings: [[String]] = []
    private var stateRevision = 0

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

    var confirming: Bool { phase == .confirmMerge || phase == .confirmUndo }
    var interactionLocked: Bool { saving || busy || confirming }
    var pending: Bool { (snapshot?.changes ?? 0) > 0 }

    // MARK: reading

    func refresh() async {
        // The settings queue performs one final read after all queued writes.
        guard !saving, !busy else { return }
        await refreshState()
    }

    private func refreshState() async {
        if let refreshTask {
            await refreshTask.value
            return
        }
        loading = true
        let revision = stateRevision
        let task = Task {
            defer {
                refreshTask = nil
                loading = false
            }
            claudeRunning = Self.isClaudeRunning()
            do {
                let state = try await Engine.state()
                guard revision == stateRevision else { return }
                snapshot = state
                loadError = nil
            } catch {
                guard revision == stateRevision else { return }
                loadError = error.localizedDescription
            }
        }
        refreshTask = task
        await task.value
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
        guard !busy, !confirming else { return }
        if let i = snapshot?.projects.firstIndex(where: { $0.path == path }) { snapshot?.projects[i].on = on }
        save(["set", "desktop", path, on ? "on" : "off"])
    }

    func setTerminal(_ path: String, on: Bool) {
        guard !busy, !confirming else { return }
        if let i = snapshot?.terminal.firstIndex(where: { $0.path == path }) { snapshot?.terminal[i].on = on }
        save(["set", "terminal", path, on ? "on" : "off"])
    }

    func setRemark(_ uuid: String, _ remark: String) {
        guard !busy, !confirming else { return }
        save(["remark", uuid, remark.trimmingCharacters(in: .whitespacesAndNewlines)])
    }

    private func save(_ args: [String]) {
        stateRevision += 1
        pendingSettings.append(args)
        guard !saving else { return }
        saving = true
        Task {
            // Let an older read finish; its revision check discards its result.
            await refreshTask?.value
            repeat {
                while !pendingSettings.isEmpty {
                    let args = pendingSettings.removeFirst()
                    do {
                        _ = try await Engine.run(args)
                    } catch {
                        phase = .failed(error.localizedDescription)
                    }
                }
                // New toggles can arrive during this read. They invalidate it and
                // keep the queue running until the persisted state is settled.
                await refreshState()
            } while !pendingSettings.isEmpty
            saving = false
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
        guard !interactionLocked else { return }
        if claudeRunning {
            phase = .confirmMerge
        } else if beginOperation("合并") {
            Task { await withClaudeClosed(verb: "合并", args: ["sync-all"]) }
        }
    }

    func undoTapped() {
        guard !interactionLocked else { return }
        phase = .confirmUndo
    }

    func cancel() {
        guard !busy else { return }
        phase = .idle
    }

    func merge() async {
        guard phase != .confirmUndo, beginOperation("合并") else { return }
        await withClaudeClosed(verb: "合并", args: ["sync-all"])
    }

    func undo() async {
        guard phase != .confirmMerge, beginOperation("撤销") else { return }
        await withClaudeClosed(verb: "撤销", args: ["undo"])
    }

    private func beginOperation(_ verb: String) -> Bool {
        guard !saving, !busy else { return false }
        stateRevision += 1
        phase = .working(verb == "合并" ? "正在合并会话…" : "正在撤销上次合并…")
        return true
    }

    /// Quits Claude, runs the engine, opens Claude again.
    private func withClaudeClosed(verb: String, args: [String]) async {
        await refreshTask?.value
        let wasRunning = Self.isClaudeRunning()
        if wasRunning {
            phase = .working("正在关闭 Claude…")
            guard await quitClaude() else {
                phase = .failed("Claude 没有退出（可能在等你确认），没有改动任何文件。")
                return
            }
        }
        phase = .working(verb == "合并" ? "正在合并会话…" : "正在撤销上次合并…")
        let result: Phase
        do {
            let message = try await Engine.run(args)
            phase = .working("正在打开 Claude…")
            openClaude()
            result = .done(message)
            notify(title: "\(verb)完成", body: message)
        } catch {
            if wasRunning { openClaude() }
            result = .failed("\(verb)失败：\(error.localizedDescription)")
        }
        await refreshState()
        phase = result
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
