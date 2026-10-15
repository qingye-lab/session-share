import Foundation
import Darwin

private let A = "aaaaaaaa-0000-0000-0000-000000000001"
private let B = "bbbbbbbb-0000-0000-0000-000000000002"
private let G = "cccccccc-0000-0000-0000-000000000003"
private let fm = FileManager.default

private func expect(_ condition: @autoclosure () -> Bool, _ message: String = "Assertion failed") throws {
    if !condition() { throw EngineError(message: message) }
}

private func throwsError(_ work: () throws -> Void) throws {
    do { try work() } catch { return }
    throw EngineError(message: "Expected an error")
}

private final class Fixture {
    let paths: NativePaths
    let engine: NativeMerge
    var a: URL { folder(A) }
    var b: URL { folder(B) }
    init() throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SESSION_SHARE_TEST_TMP"] ?? NSTemporaryDirectory())
            .appendingPathComponent("session-share-native-\(UUID().uuidString)")
        paths = NativePaths(home: root)
        engine = NativeMerge(paths: paths, running: { false })
        try NativeIO.privateDirectory(paths.state)
        _ = folder(A); _ = folder(B)
        try put(paths.support.appendingPathComponent("Claude/config.json"), ["lastKnownAccountUuid": A])
    }
    deinit { try? fm.removeItem(at: paths.home) }
    @discardableResult func folder(_ id: String, data: String = "Claude") -> URL {
        let p = paths.support.appendingPathComponent("\(data)/claude-code-sessions/\(id)/org")
        try! NativeIO.privateDirectory(p)
        return p
    }
    func put(_ file: URL, _ object: Any) throws {
        try NativeIO.privateDirectory(file.deletingLastPathComponent())
        try NativeIO.writeJSON(file, object)
    }
    @discardableResult func session(_ folder: URL, _ n: Int, at: Double = 100, title: String = "title", project: String = "/p", archived: Bool = false) throws -> String {
        let id = String(format: "%08d", n)
        let sid = "local_\(id)-0000-0000-0000-000000000000"
        let cli = "\(id)-cccc-0000-0000-000000000000"
        try put(folder.appendingPathComponent(sid + ".json"), ["sessionId": sid, "cliSessionId": cli, "cwd": project, "title": title, "lastActivityAt": at, "isArchived": archived])
        let transcript = paths.projects.appendingPathComponent("project/\(cli).jsonl")
        try NativeIO.privateDirectory(transcript.deletingLastPathComponent())
        try Data().write(to: transcript)
        return sid
    }
    @discardableResult func command(_ args: String...) throws -> String { try engine.command(args) }
    func state() throws -> Snapshot { try JSONDecoder().decode(Snapshot.self, from: Data(engine.command(["state"]).utf8)) }
    func records(_ folder: URL) -> [String] { NativeIO.list(folder).filter { $0.hasPrefix("local_") } }
    func object(_ folder: URL, _ sid: String) -> JSONObject { NativeIO.read(folder.appendingPathComponent(sid + ".json"))! }
    func tombstone(_ folder: URL, _ sid: String, at: Double) throws {
        try NativeIO.write(folder.appendingPathComponent("deleted_" + sid.dropFirst(6)), Data(String(format: "%.0f", at).utf8))
    }
    @discardableResult func transcript(_ id: String = "11111111-1111-4000-8000-000000000001", project: String = "/terminal", entry: String = "cli", text: String = "Hello world", title: String? = "终端任务", custom: String? = nil) throws -> URL {
        let file = paths.projects.appendingPathComponent("terminal/\(id).jsonl")
        try NativeIO.privateDirectory(file.deletingLastPathComponent())
        var lines: [JSONObject] = [
            ["type": "user", "cwd": project, "entrypoint": entry, "timestamp": "2026-10-01T00:00:00.000Z", "message": ["role": "user", "content": text]],
            ["type": "assistant", "timestamp": "2026-10-01T00:05:00.000Z"]
        ]
        if let title { lines.append(["type": "ai-title", "aiTitle": title]) }
        if let custom { lines.append(["type": "custom-title", "customTitle": custom]) }
        let data = try lines.map { String(decoding: try NativeIO.encode($0), as: UTF8.self) }.joined(separator: "\n") + "\n"
        try Data(data.utf8).write(to: file)
        return file
    }
}

@main
struct NativeEngineTests {
    static func main() throws {
        var passed = 0
        func test(_ name: String, _ work: (Fixture) throws -> Void) throws {
            let f = try Fixture()
            do { try work(f); passed += 1; print("PASS \(name)") }
            catch { print("FAIL \(name): \(error.localizedDescription)"); exit(1) }
        }
        try test("preview never writes session lists") { f in
            try f.session(f.a, 1)
            let s = try f.state()
            try expect(s.changes == 1 && s.sessions == 1)
            try expect(f.records(f.b).isEmpty)
        }
        try test("two-way merge and byte preservation") { f in
            let sid = try f.session(f.a, 1)
            try f.session(f.b, 2)
            let before = try Data(contentsOf: f.a.appendingPathComponent(sid + ".json"))
            try f.command("sync-all")
            try expect(f.records(f.a) == f.records(f.b))
            let after = try Data(contentsOf: f.b.appendingPathComponent(sid + ".json"))
            try expect(before == after)
        }
        try test("newer session wins") { f in
            let sid = try f.session(f.a, 1, at: 100, title: "old")
            try f.session(f.b, 1, at: 300, title: "new")
            try f.command("sync-all")
            try expect(f.object(f.a, sid)["title"] as? String == "new")
        }
        try test("modification time breaks equal activity ties") { f in
            let sid = try f.session(f.a, 1, title: "old")
            try f.session(f.b, 1, title: "new")
            try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: f.a.appendingPathComponent(sid + ".json").path)
            try f.command("sync-all")
            try expect(f.object(f.a, sid)["title"] as? String == "new")
        }
        try test("running Claude blocks writes") { f in
            try f.session(f.a, 1)
            f.engine.running = { true }
            try throwsError { _ = try f.command("sync-all") }
            try expect(f.records(f.b).isEmpty)
            _ = try f.state()
        }
        try test("gateway participates") { f in
            let g = f.folder(G, data: "Claude-3p")
            let sid = try f.session(f.a, 1)
            try f.command("sync-all")
            try expect(f.records(g) == [sid + ".json"])
            let s = try f.state()
            try expect(s.accounts.last?.gateway == true && s.accounts.last?.name == "网关模式")
        }
        try test("deletions spread") { f in
            let sid = try f.session(f.a, 1)
            try f.tombstone(f.b, sid, at: 500)
            try f.command("sync-all")
            try expect(f.records(f.a).isEmpty)
        }
        try test("newest deletion timestamp spreads") { f in
            let sid = try f.session(f.a, 1)
            try f.tombstone(f.a, sid, at: 200)
            try f.tombstone(f.b, sid, at: 500)
            try f.command("sync-all")
            let ts = try String(contentsOf: f.a.appendingPathComponent("deleted_" + sid.dropFirst(6)), encoding: .utf8)
            try expect(ts == "500")
        }
        try test("session used after deletion remains") { f in
            let sid = try f.session(f.a, 1, at: 900)
            try f.tombstone(f.b, sid, at: 500)
            try f.command("sync-all")
            try expect(f.records(f.b) == [sid + ".json"])
        }
        try test("archive index follows actual selected sessions") { f in
            let sid = try f.session(f.a, 1, archived: true)
            try f.command("set", "desktop", "/p", "off")
            try f.command("sync-all")
            try expect(!NativeIO.exists(f.b.appendingPathComponent(NativeIO.index)))
            try expect(NativeIO.read(f.a.appendingPathComponent(NativeIO.index))?["archived"] as? [String] == [sid])
        }
        try test("unknown archive format stops all writes") { f in
            try f.session(f.a, 1)
            try f.put(f.a.appendingPathComponent(NativeIO.index), ["v": 2, "items": []])
            try throwsError { _ = try f.command("sync-all") }
            try expect(f.records(f.b).isEmpty)
        }
        try test("unreadable session is warned and skipped") { f in
            try Data("broken".utf8).write(to: f.a.appendingPathComponent("local_bad.json"))
            let s = try f.state()
            try expect(s.warnings.count == 1 && s.sessions == 0)
        }
        try test("account-specific files untouched") { f in
            try f.session(f.a, 1)
            try f.put(f.a.appendingPathComponent("scheduled-tasks.json"), ["private": true])
            try f.command("sync-all")
            try expect(!NativeIO.exists(f.b.appendingPathComponent("scheduled-tasks.json")))
        }
        try test("second merge is a no-op without extra backup") { f in
            try f.session(f.a, 1, archived: true)
            try f.command("sync-all")
            try expect(tryState(f).changes == 0)
            try f.command("sync-all")
            try expect(NativeIO.list(f.paths.state.appendingPathComponent("backups")).count == 1)
        }
        try test("written sessions have owner-only permissions") { f in
            let sid = try f.session(f.a, 1)
            try f.command("sync-all")
            let attrs = try fm.attributesOfItem(atPath: f.b.appendingPathComponent(sid + ".json").path)
            try expect((attrs[.posixPermissions] as? Int) == 0o600)
        }
        try test("project exclusion prevents additions but updates existing copies") { f in
            let sid = try f.session(f.a, 1)
            try f.command("set", "desktop", "/p", "off")
            try f.command("sync-all")
            try expect(f.records(f.b).isEmpty)
            try f.session(f.b, 1, at: 300, title: "new")
            try f.command("sync-all")
            try expect(f.object(f.a, sid)["title"] as? String == "new")
        }
        try test("terminal import is opt-in and deterministic") { f in
            try f.transcript()
            try expect(tryState(f).imports == 0)
            try f.command("set", "terminal", "/terminal", "on")
            try expect(tryState(f).imports == 1)
            try f.command("sync-all")
            try expect(f.records(f.a) == f.records(f.b) && f.records(f.a).count == 1)
            let record = f.object(f.a, String(f.records(f.a)[0].dropLast(5)))
            try expect(record["permissionMode"] as? String == "default")
            try expect(record["title"] as? String == "终端任务")
            try expect(tryState(f).changes == 0)
        }
        try test("desktop transcripts and command wrappers are excluded") { f in
            try f.transcript(entry: "claude-desktop")
            try f.transcript("22222222-0000-4000-8000-000000000002", text: "<command-name>/clear</command-name>")
            try expect(tryState(f).terminal.isEmpty)
        }
        try test("deleted imports never resurrect") { f in
            try f.transcript()
            try f.command("set", "terminal", "/terminal", "on")
            try f.command("sync-all")
            let sid = String(f.records(f.a)[0].dropLast(5))
            try f.tombstone(f.a, sid, at: NativeIO.now())
            try f.command("sync-all")
            try expect(f.records(f.a).isEmpty && f.records(f.b).isEmpty)
            try expect(tryState(f).imports == 0)
        }
        try test("undo restores last merge but preserves later changes") { f in
            let sid = try f.session(f.a, 1)
            let other = try f.session(f.b, 2)
            try f.command("sync-all")
            try f.session(f.b, 1, at: 999, title: "later")
            try f.command("undo")
            try expect(!f.records(f.a).contains(other + ".json"))
            try expect(f.object(f.b, sid)["title"] as? String == "later")
            try expect(tryState(f).lastRun == nil)
        }
        try test("undo rebuilds index for retained archived session") { f in
            let sid = try f.session(f.a, 1, archived: true)
            try f.command("sync-all")
            try f.session(f.b, 1, at: 999, title: "later", archived: true)
            try f.command("undo")
            try expect(NativeIO.read(f.b.appendingPathComponent(NativeIO.index))?["archived"] as? [String] == [sid])
        }
        try test("only three backups survive rapid writes") { f in
            for n in 1...5 { try f.session(f.a, n); try f.command("sync-all") }
            try expect(NativeIO.list(f.paths.state.appendingPathComponent("backups")).count == 3)
        }
        try test("names emails remarks and unknown settings survive") { f in
            try f.put(f.paths.home.appendingPathComponent(".claude.json"), ["oauthAccount": ["accountUuid": A, "displayName": "Demo", "emailAddress": "demo@example.com"]])
            try f.put(f.paths.state.appendingPathComponent("settings.json"), ["customFutureKey": 42])
            try f.command("remark", A, "工作号")
            let s = try f.state()
            try expect(s.accounts[0].name == "工作号" && s.accounts[0].email == "demo@example.com")
            try expect(NativeIO.read(f.paths.state.appendingPathComponent("settings.json"))?["customFutureKey"] as? Int == 42)
            try f.command("remark", A, "")
            try expect(tryState(f).accounts[0].name == "Demo")
        }
        try test("worktrees map to owning project") { f in
            try f.session(f.a, 1, project: "/repo/.claude/worktrees/feature")
            try expect(tryState(f).projects.first?.path == "/repo")
        }
        try test("origins remain stable after copying") { f in
            try f.session(f.a, 1)
            try f.command("sync-all")
            let from = try f.state().projects[0].from
            try expect(from.count == 1 && from[0].name == "账号 aaaaaaaa")
        }
        try test("custom title overrides AI title; spaced JSON supported") { f in
            let file = try f.transcript(custom: "用户命名")
            let t = try NativeTranscripts.read(file)
            try expect(t?.title == "用户命名")
        }
        try test("streaming titles across chunks and huge lines") { f in
            let file = try f.transcript(title: nil)
            let h = try FileHandle(forWritingTo: file)
            try h.seekToEnd()
            try h.write(contentsOf: Data(("{\"type\":\"assistant\",\"payload\":\"" + String(repeating: "a", count: 5 * 1024 * 1024) + "\"}\n").utf8))
            try h.write(contentsOf: NativeIO.encode(["type": "custom-title", "customTitle": "跨块标题"]))
            try h.close()
            let t = try NativeTranscripts.read(file)
            try expect(t?.title == "跨块标题")
        }
        try test("cache tracks transcript updates") { f in
            let file = try f.transcript()
            _ = try f.state()
            let h = try FileHandle(forWritingTo: file); try h.seekToEnd()
            try h.write(contentsOf: NativeIO.encode(["type": "custom-title", "customTitle": "更新标题"]))
            try h.close()
            let t = try NativeTranscripts.scan(f.paths)
            try expect(t.first?.title == "更新标题")
        }
        try test("cross-process lock blocks concurrent command") { f in
            let lock = try NativeLock(f.paths.state)
            try throwsError { _ = try f.state() }
            withExtendedLifetime(lock) {}
        }
        try test("malformed archive version and traversal rejected before restore") { f in
            try f.session(f.a, 1); try f.command("sync-all")
            let file = f.paths.state.appendingPathComponent("last-run.json")
            var last = NativeIO.read(file)!
            last["ops"] = [["file": "../../outside", "after": NSNull()]]
            try f.put(file, last)
            try throwsError { _ = try f.command("undo") }
            try expect(f.records(f.a).count == 1)
        }
        try test("import ID is identical to the legacy engine") { _ in
            try expect(NativeIO.importID("11111111-1111-4000-8000-000000000001") == "local_626427ec-c2dd-537e-bfd4-09371967e622")
        }
        try test("legacy JSON settings and backup manifest can be undone") { f in
            let sid = try f.session(f.a, 1)
            let backupDir = f.paths.state.appendingPathComponent("backups")
            try NativeIO.privateDirectory(backupDir)
            let backup = backupDir.appendingPathComponent("sessions-20261001-000000-000.tar.gz")
            _ = try NativeIO.process("/usr/bin/tar", ["-czf", backup.path, "-C", f.paths.support.path, "Claude/claude-code-sessions"], temp: f.paths.state)
            let file = f.b.appendingPathComponent(sid + ".json")
            let body = try Data(contentsOf: f.a.appendingPathComponent(sid + ".json"))
            try NativeIO.write(file, body)
            let relative = String(file.path.dropFirst(f.paths.support.path.count + 1))
            // Fields and hashes used by core.mjs v0.4.0.
            try f.put(f.paths.state.appendingPathComponent("last-run.json"), ["at": 100, "backup": backup.path,
                                                                           "ops": [["file": relative, "after": NativeIO.hash(body)]]])
            try f.command("undo")
            try expect(f.records(f.b).isEmpty && f.records(f.a).count == 1)
        }
        try test("undo cannot follow a session symlink") { f in
            let sid = try f.session(f.a, 1)
            try f.command("sync-all")
            let target = f.paths.home.appendingPathComponent("outside.json")
            try Data("untouched".utf8).write(to: target)
            let file = f.b.appendingPathComponent(sid + ".json")
            try fm.removeItem(at: file)
            try fm.createSymbolicLink(at: file, withDestinationURL: target)
            try throwsError { _ = try f.command("undo") }
            let contents = try String(contentsOf: target, encoding: .utf8)
            try expect(contents == "untouched")
        }
        try test("invalid settings command makes no changes") { f in
            try throwsError { _ = try f.command("set", "desktop", "/p", "maybe") }
            try throwsError { _ = try f.command("remark", "invalid", "test") }
            try expect(!NativeIO.exists(f.paths.state.appendingPathComponent("settings.json")))
        }
        print("\(passed) native tests passed")
    }
    private static func tryState(_ f: Fixture) -> Snapshot { try! f.state() }
}
