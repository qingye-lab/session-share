import Foundation
import AppKit

private struct NativeFolder {
    var data: String
    var account: String
    var url: URL
    var key: String { data + "/" + account }
}

private struct NativeSession {
    var raw: Data
    var time: Double
    var modified: Double
    var archived: Bool
    var cli: String
    var project: String
    var imported = false
}

private struct NativeFolderState {
    var sessions: [String: NativeSession] = [:]
    var deleted: [String: Double] = [:]
    var archived: [String]?
}

private struct NativeOperation {
    var file: URL
    var kind: String
    var body: Data?
}

private struct NativeGroup {
    var count = 0
    var latest: Double = 0
    var from: [String: Int] = [:]
    var terminal = 0
    var terminalLatest: Double = 0
}

struct NativePlan {
    var snapshot: Snapshot
    var written = 0
    var backup: URL?
}

// Commands run on Engine's serial queue. The cross-process lock protects the
// plan as well as its writes, preventing stale plans and lost settings.
final class NativeMerge {
    let paths: NativePaths
    var running: () -> Bool

    init(paths: NativePaths = NativePaths(), running: @escaping () -> Bool = {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.anthropic.claudefordesktop").isEmpty
    }) {
        self.paths = paths
        self.running = running
    }

    func command(_ args: [String]) throws -> String {
        let lock = try NativeLock(paths.state)
        defer { withExtendedLifetime(lock) {} }
        switch args.first {
        case "state", "status":
            let s = try plan().snapshot
            if args.first == "state" { return String(decoding: try JSONEncoder().encode(s), as: UTF8.self) }
            return "共 \(s.sessions) 个会话，\(s.accounts.count) 个账号目录，待写入 \(s.changes) 处。\n" + s.accounts.map {
                "\($0.name)：已有 \($0.have)，新增 \($0.add)，更新 \($0.update)，删除 \($0.remove)"
            }.joined(separator: "\n")
        case "sync-all":
            guard !running() else { throw EngineError(message: "Claude 还在运行，请先退出") }
            let result = try plan(write: true)
            let s = result.snapshot
            return result.written == 0 ? "无需改动，共 \(s.sessions) 个会话。" :
                "已合并 \(s.accounts.count) 个账号目录，写入 \(result.written) 处\(s.imports > 0 ? "，导入 \(s.imports) 个终端会话" : "")。"
        case "set":
            guard args.count == 4, ["desktop", "terminal"].contains(args[1]), !args[2].isEmpty, ["on", "off"].contains(args[3]) else {
                throw EngineError(message: "用法：set desktop|terminal <文件夹> on|off")
            }
            var s = settings()
            let key = args[1] == "terminal" ? "terminal" : "projects"
            var values = s[key] as? JSONObject ?? [:]
            values[args[2]] = args[3] == "on"
            s[key] = values
            try saveSettings(s)
            return ""
        case "remark":
            guard args.count >= 2, UUID(uuidString: args[1]) != nil else { throw EngineError(message: "账号 ID 无效") }
            var s = settings(), accounts = s["accounts"] as? JSONObject ?? [:]
            var account = accounts[args[1]] as? JSONObject ?? [:]
            let value = args.dropFirst(2).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            account["remark"] = value.isEmpty ? nil : value
            accounts[args[1]] = account
            s["accounts"] = accounts
            try saveSettings(s)
            return ""
        case "undo":
            guard !running() else { throw EngineError(message: "Claude 还在运行，请先退出") }
            return try undo()
        default:
            throw EngineError(message: "用法：state | status | sync-all | undo | set | remark")
        }
    }

    private func settings() -> JSONObject {
        var s = NativeIO.read(paths.state.appendingPathComponent("settings.json")) ?? [:]
        s["v"] = 1
        for key in ["accounts", "projects", "terminal"] where s[key] == nil { s[key] = JSONObject() }
        return s
    }
    private func saveSettings(_ s: JSONObject) throws { try NativeIO.writeJSON(paths.state.appendingPathComponent("settings.json"), s) }

    private func learnAccounts(_ s: inout JSONObject) throws {
        var accounts = s["accounts"] as? JSONObject ?? [:]
        let files = [paths.home.appendingPathComponent(".claude.json")] + NativeIO.list(paths.home)
            .filter { $0.hasPrefix(".claude") }.map { paths.home.appendingPathComponent($0 + "/.claude.json") }
        var changed = false
        for file in files {
            guard let a = NativeIO.read(file)?["oauthAccount"] as? JSONObject, let uuid = a["accountUuid"] as? String else { continue }
            var current = accounts[uuid] as? JSONObject ?? [:]
            let name = a["displayName"] as? String ?? a["fullName"] as? String ?? ""
            let email = a["emailAddress"] as? String ?? ""
            if current["name"] as? String != name || current["email"] as? String != email {
                current["name"] = name; current["email"] = email; accounts[uuid] = current; changed = true
            }
        }
        if changed { s["accounts"] = accounts; try saveSettings(s) }
    }

    private func folders() -> [NativeFolder] {
        var out: [NativeFolder] = []
        for data in NativeIO.dataDirs {
            let base = paths.support.appendingPathComponent(data + "/claude-code-sessions")
            for account in NativeIO.list(base) {
                let accountDir = base.appendingPathComponent(account)
                guard NativeIO.directory(accountDir) else { continue }
                for org in NativeIO.list(accountDir) {
                    let url = accountDir.appendingPathComponent(org)
                    if NativeIO.directory(url) { out.append(.init(data: data, account: account, url: url)) }
                }
            }
        }
        return out
    }

    private func readFolder(_ folder: URL, warnings: inout [String]) throws -> NativeFolderState {
        var result = NativeFolderState()
        for name in NativeIO.list(folder) {
            let file = folder.appendingPathComponent(name)
            guard !NativeIO.isLink(file) else { throw EngineError(message: "不支持会话目录中的符号链接：\(name)") }
            if name.hasPrefix("local_"), name.hasSuffix(".json") {
                let sid = String(name.dropLast(5))
                guard let raw = try? Data(contentsOf: file), let data = NativeIO.json(raw), data["sessionId"] as? String == sid,
                      let cli = data["cliSessionId"] as? String else {
                    warnings.append("跳过无法识别的会话文件：\(name)")
                    continue
                }
                let time = [data["lastActivityAt"], data["createdAt"]].compactMap { $0 as? Double }.first { $0 > 0 && $0.rounded() == $0 }
                    ?? floor(NativeIO.millis(file))
                result.sessions[sid] = .init(raw: raw, time: time, modified: NativeIO.millis(file), archived: data["isArchived"] as? Bool ?? false,
                                             cli: cli, project: NativeIO.project(data["cwd"] as? String))
            } else if name.hasPrefix("deleted_") {
                let text = try String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
                result.deleted["local_" + name.dropFirst(8)] = Double(text) ?? floor(NativeIO.millis(file))
            } else if name == NativeIO.index {
                guard let idx = NativeIO.read(file), idx["v"] as? Int == 1, let archived = idx["archived"] as? [String] else {
                    throw EngineError(message: "归档索引格式不支持：\(file.path)")
                }
                result.archived = archived
            }
        }
        return result
    }

    func plan(write: Bool = false) throws -> NativePlan {
        var s = settings()
        try learnAccounts(&s)
        let accountSettings = s["accounts"] as? JSONObject ?? [:]
        let selected = s["projects"] as? [String: Bool] ?? [:]
        let terminalSelected = s["terminal"] as? [String: Bool] ?? [:]
        let folders = folders()
        var warnings: [String] = []
        let states = try folders.map { try readFolder($0.url, warnings: &warnings) }
        var winners: [String: NativeSession] = [:], deleted: [String: Double] = [:]
        for state in states {
            for (sid, session) in state.sessions {
                if let old = winners[sid], old.time > session.time || (old.time == session.time && old.modified >= session.modified) { continue }
                winners[sid] = session
            }
            for (sid, ts) in state.deleted { deleted[sid] = max(deleted[sid] ?? 0, ts) }
        }
        for (sid, ts) in deleted {
            if let session = winners[sid], session.time > ts { deleted[sid] = nil }
            else { winners[sid] = nil }
        }

        let originFile = paths.state.appendingPathComponent("origins.json")
        var origins = NativeIO.read(originFile) as? [String: [String]] ?? [:]
        var holders: [String: Set<String>] = [:]
        for (i, f) in folders.enumerated() {
            for (sid, session) in states[i].sessions {
                if sid == NativeIO.importID(session.cli) { holders[sid] = ["terminal"] }
                else { holders[sid, default: []].insert(f.key) }
            }
        }
        var originsChanged = false
        for (sid, keys) in holders where origins[sid] == nil { origins[sid] = keys.sorted(); originsChanged = true }
        if originsChanged { try NativeIO.writeJSON(originFile, origins) }

        var groups: [String: NativeGroup] = [:]
        for (sid, w) in winners {
            var g = groups[w.project] ?? NativeGroup()
            g.count += 1; g.latest = max(g.latest, w.time)
            for origin in origins[sid] ?? [] { g.from[origin, default: 0] += 1 }
            groups[w.project] = g
        }
        let known = Set(states.flatMap { $0.sessions.values.map(\.cli) })
        var imports = 0
        for t in try NativeTranscripts.scan(paths) {
            let sid = NativeIO.importID(t.cli)
            if known.contains(t.cli) || deleted[sid] != nil || winners[sid] != nil { continue }
            var g = groups[t.project] ?? NativeGroup()
            g.terminal += 1; g.terminalLatest = max(g.terminalLatest, t.latest); groups[t.project] = g
            guard terminalSelected[t.project] == true else { continue }
            let raw = try NativeIO.encode(["sessionId": sid, "cliSessionId": t.cli, "cwd": t.cwd, "originCwd": t.cwd,
                                          "title": t.title, "titleSource": "auto", "createdAt": t.created,
                                          "lastActivityAt": t.latest, "isArchived": false, "permissionMode": "default"])
            winners[sid] = .init(raw: raw, time: t.latest, modified: 0, archived: false, cli: t.cli, project: t.project, imported: true)
            imports += 1
        }
        let transcripts = Set(NativeIO.list(paths.projects).flatMap { dir in
            NativeIO.list(paths.projects.appendingPathComponent(dir)).filter { $0.hasSuffix(".jsonl") }.map { String($0.dropLast(6)) }
        })
        var accounts: [Snapshot.Account] = [], todo: [NativeOperation] = []
        for (i, f) in folders.enumerated() {
            let state = states[i]
            var ops: [NativeOperation] = [], archived: [String] = []
            for sid in winners.keys.sorted() {
                let w = winners[sid]!
                let have = state.sessions[sid]
                if have == nil {
                    guard w.imported || selected[w.project] != false else { continue }
                    ops.append(.init(file: f.url.appendingPathComponent(sid + ".json"), kind: "add", body: w.raw))
                } else if have!.raw != w.raw {
                    ops.append(.init(file: f.url.appendingPathComponent(sid + ".json"), kind: "update", body: w.raw))
                }
                if w.archived { archived.append(sid) }
            }
            for sid in deleted.keys.sorted() {
                if state.sessions[sid] != nil { ops.append(.init(file: f.url.appendingPathComponent(sid + ".json"), kind: "remove")) }
                if state.deleted[sid] == nil || state.deleted[sid]! < deleted[sid]! {
                    let ts = String(format: "%.0f", deleted[sid]!)
                    ops.append(.init(file: f.url.appendingPathComponent("deleted_" + sid.dropFirst(6)), kind: "tombstone", body: Data(ts.utf8)))
                }
            }
            if archived != (state.archived ?? []).sorted(), !archived.isEmpty || state.archived != nil {
                ops.append(.init(file: f.url.appendingPathComponent(NativeIO.index), kind: "archive-index", body: try NativeIO.encode(["v": 1, "archived": archived])))
            }
            let a = accountSettings[f.account] as? JSONObject ?? [:]
            let gateway = f.data == "Claude-3p"
            let name = gateway ? "网关模式" : [a["remark"], a["name"], a["email"]].compactMap { $0 as? String }.first { !$0.isEmpty } ?? "账号 \(f.account.prefix(8))"
            let current = NativeIO.read(paths.support.appendingPathComponent(f.data + "/config.json"))?["lastKnownAccountUuid"] as? String
            accounts.append(.init(key: f.key, uuid: f.account, gateway: gateway, name: name, email: gateway ? "" : a["email"] as? String ?? "",
                                  remark: gateway ? "" : a["remark"] as? String ?? "", signedIn: !gateway && current == f.account,
                                  have: state.sessions.count, add: ops.filter { $0.kind == "add" }.count,
                                  update: ops.filter { $0.kind == "update" }.count, remove: ops.filter { $0.kind == "remove" }.count))
            todo += ops
        }
        let names = Dictionary(uniqueKeysWithValues: groups.keys.map { p -> (String, String) in
            let base = URL(fileURLWithPath: p).lastPathComponent
            let repeated = groups.keys.filter { URL(fileURLWithPath: $0).lastPathComponent == base }.count > 1
            let name = p == paths.home.path ? "~" : repeated ? p.split(separator: "/").suffix(2).joined(separator: "/") : base.isEmpty ? p : base
            return (p, name)
        })
        func originName(_ key: String) -> String {
            if key == "terminal" { return "终端" }
            return accounts.first { $0.key == key }?.name ?? "账号 \(key.split(separator: "/").last?.prefix(8) ?? "未知")"
        }
        let projects = groups.filter { $0.value.count > 0 }.sorted { $0.value.latest == $1.value.latest ? $0.key < $1.key : $0.value.latest > $1.value.latest }.map { p, g in
            Snapshot.Project(path: p, name: names[p]!, count: g.count, latest: g.latest, on: selected[p] != false,
                             from: g.from.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.map { .init(name: originName($0.key), count: $0.value) })
        }
        let terminal = groups.filter { $0.value.terminal > 0 }.sorted { $0.value.terminalLatest == $1.value.terminalLatest ? $0.key < $1.key : $0.value.terminalLatest > $1.value.terminalLatest }.map { p, g in
            Snapshot.TerminalGroup(path: p, name: names[p]!, count: g.terminal, latest: g.terminalLatest, on: terminalSelected[p] == true)
        }
        var result = NativePlan(snapshot: .init(sessions: winners.count, changes: todo.count, imports: imports,
                                              missing: winners.values.filter { !transcripts.contains($0.cli) }.count,
                                              warnings: warnings, lastRun: lastRun().map { .init(at: $0["at"] as? Double ?? 0, changes: ($0["ops"] as? [JSONObject])?.count ?? 0) },
                                              accounts: accounts, projects: projects, terminal: terminal))
        if write && !todo.isEmpty {
            guard !running() else { throw EngineError(message: "Claude 重新启动了，没有写入任何会话文件") }
            result.backup = try backup()
            let operations: [JSONObject] = todo.map { op in
                ["file": String(op.file.path.dropFirst(paths.support.path.count + 1)), "after": op.body.map(NativeIO.hash) as Any? ?? NSNull()]
            }
            try NativeIO.writeJSON(paths.state.appendingPathComponent("last-run.json"), ["at": NativeIO.now(), "backup": result.backup!.path, "ops": operations])
            for op in todo {
                if let body = op.body { try NativeIO.write(op.file, body) }
                else { try NativeIO.remove(op.file) }
            }
            result.written = todo.count
        }
        return result
    }

    func lastRun() -> JSONObject? {
        guard let last = NativeIO.read(paths.state.appendingPathComponent("last-run.json")), let p = last["backup"] as? String,
              NativeIO.exists(URL(fileURLWithPath: p)) else { return nil }
        return last
    }

    private func backup() throws -> URL {
        let dir = paths.state.appendingPathComponent("backups")
        try NativeIO.privateDirectory(dir)
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyyMMdd-HHmmss-SSS"
        var name = "sessions-\(f.string(from: Date())).tar.gz"
        if NativeIO.exists(dir.appendingPathComponent(name)) { name = "sessions-\(f.string(from: Date()))-\(UUID().uuidString.prefix(6)).tar.gz" }
        let file = dir.appendingPathComponent(name)
        let parts = NativeIO.dataDirs.map { $0 + "/claude-code-sessions" }.filter { NativeIO.directory(paths.support.appendingPathComponent($0)) }
        guard !parts.isEmpty else { throw EngineError(message: "找不到可备份的会话目录") }
        do {
            _ = try NativeIO.process("/usr/bin/tar", ["-czf", file.path, "-C", paths.support.path] + parts, temp: paths.state)
            try NativeIO.fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch { try? NativeIO.remove(file); throw error }
        for old in NativeIO.list(dir).filter({ $0.hasPrefix("sessions-") && $0.hasSuffix(".tar.gz") }).dropLast(3) {
            try NativeIO.remove(dir.appendingPathComponent(old))
        }
        return file
    }

    private func checkedPath(_ relative: String) throws -> URL {
        let pieces = relative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard pieces.count == 5, NativeIO.dataDirs.contains(pieces[0]), pieces[1] == "claude-code-sessions",
              pieces.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              (pieces[4].hasPrefix("local_") && pieces[4].hasSuffix(".json")) || pieces[4].hasPrefix("deleted_") || pieces[4] == NativeIO.index else {
            throw EngineError(message: "撤销清单包含无效路径")
        }
        var file = paths.support
        for piece in pieces {
            file.appendPathComponent(piece)
            if NativeIO.isLink(file) { throw EngineError(message: "撤销路径包含符号链接") }
        }
        return file
    }

    private func undo() throws -> String {
        guard let last = lastRun(), let name = last["backup"] as? String, let ops = last["ops"] as? [JSONObject] else { throw EngineError(message: "没有可以撤销的合并") }
        let archive = URL(fileURLWithPath: name).standardizedFileURL
        guard archive.deletingLastPathComponent() == paths.state.appendingPathComponent("backups").standardizedFileURL, !NativeIO.isLink(archive) else {
            throw EngineError(message: "备份路径无效")
        }
        let items = try ops.map { op -> (String, URL, String?) in
            guard let relative = op["file"] as? String else { throw EngineError(message: "撤销清单无效") }
            return (relative, try checkedPath(relative), op["after"] as? String)
        }
        // Inspect only requested members. Never extract an archive wholesale.
        let listing = try NativeIO.process("/usr/bin/tar", ["-tzf", archive.path], temp: paths.state)
        let members = Set(String(decoding: listing, as: UTF8.self).split(separator: "\n").map(String.init))
        var restore: [(URL, Data?)] = [], kept = 0
        for (relative, file, after) in items {
            let current = try NativeIO.exists(file) ? NativeIO.hash(Data(contentsOf: file)) : nil
            if current != after { kept += 1; continue }
            let before = members.contains(relative) ? try NativeIO.process("/usr/bin/tar", ["-xOzf", archive.path, "--", relative], temp: paths.state) : nil
            restore.append((file, before))
        }
        guard !running() else { throw EngineError(message: "Claude 重新启动了，请先退出") }
        _ = try backup()
        for (file, body) in restore {
            if let body { try NativeIO.write(file, body) } else { try NativeIO.remove(file) }
        }
        // Files used since the merge are preserved. Rebuild affected indexes so
        // they cannot reference restored-away sessions or miss retained ones.
        let affected = Set(items.map { $0.1.deletingLastPathComponent() })
        for folder in affected {
            var warnings: [String] = []
            let state = try readFolder(folder, warnings: &warnings)
            let archived = state.sessions.filter { $0.value.archived }.keys.sorted()
            if state.archived != nil || !archived.isEmpty {
                try NativeIO.writeJSON(folder.appendingPathComponent(NativeIO.index), ["v": 1, "archived": archived])
            }
        }
        try NativeIO.remove(paths.state.appendingPathComponent("last-run.json"))
        return "已撤销上次合并：恢复 \(restore.count) 处\(kept > 0 ? "，\(kept) 处之后又被改过，保留现状" : "")"
    }
}
