import Foundation

// Synthetic accounts/projects for screenshots; requires an empty destination.
@main
struct DemoData {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { throw EngineError(message: "Usage: demo-data <empty-directory>") }
        let root = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
        try NativeIO.privateDirectory(root)
        guard NativeIO.list(root).isEmpty else { throw EngineError(message: "Demo directory must be empty") }
        func put(_ path: String, _ object: Any) throws {
            let file = root.appendingPathComponent(path)
            try NativeIO.privateDirectory(file.deletingLastPathComponent())
            try NativeIO.writeJSON(file, object)
        }
        let a = "aaaaaaaa-0000-4000-8000-000000000001"
        let b = "bbbbbbbb-0000-4000-8000-000000000002"
        let gateway = "cccccccc-0000-4000-8000-000000000003"
        let org = "00000000-0000-4000-8000-000000000001"
        let support = "Library/Application Support"
        for (data, account) in [("Claude", a), ("Claude", b), ("Claude-3p", gateway)] {
            try NativeIO.privateDirectory(root.appendingPathComponent("\(support)/\(data)/claude-code-sessions/\(account)/\(org)"))
            if account != b { try put("\(support)/\(data)/config.json", ["lastKnownAccountUuid": account]) }
        }
        try put(".claude.json", ["oauthAccount": ["accountUuid": b, "displayName": "Alex", "emailAddress": "alex@example.com"]])
        try put("\(support)/session-share/settings.json", ["v": 1, "accounts": [a: ["remark": "个人账号"]], "projects": JSONObject(), "terminal": JSONObject()])
        let projects = ["website", "notes-app", "design-system", "api-server", "small-tools", "portfolio"]
        var number = 0
        for (i, project) in projects.enumerated() {
            for k in 0..<(i % 3 + 2) {
                number += 1
                let n = String(format: "%08d", number)
                let cli = "\(n)-1111-4000-8000-000000000000"
                let sid = "local_\(n)-2222-4000-8000-000000000000"
                let cwd = "/Users/demo/Projects/\(project)"
                try put("\(support)/Claude/claude-code-sessions/\(i % 2 == 0 ? a : b)/\(org)/\(sid).json", ["sessionId": sid, "cliSessionId": cli, "cwd": cwd, "title": "\(project) demo \(k + 1)", "lastActivityAt": floor(NativeIO.now()) - Double(i * 3600000 + k * 60000), "isArchived": false])
                let file = root.appendingPathComponent(".claude/projects/\(project)/\(cli).jsonl")
                try NativeIO.privateDirectory(file.deletingLastPathComponent())
                try Data().write(to: file)
            }
            let cli = "eeeeeeee-0000-4000-8000-\(String(format: "%012d", i))"
            let file = root.appendingPathComponent(".claude/projects/\(project)/\(cli).jsonl")
            let d = try NativeIO.encode(["type": "user", "entrypoint": "cli", "cwd": "/Users/demo/Projects/\(project)", "sessionId": cli,
                                        "timestamp": ISO8601DateFormatter().string(from: Date()), "message": ["role": "user", "content": "Review the \(project) project"]])
            var line = d; line.append(10); try line.write(to: file)
        }
        print(root.path)
    }
}
