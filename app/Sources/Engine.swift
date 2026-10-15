import Foundation

// The merge itself lives in cli.mjs/core.mjs inside the app's Resources; this
// runs it and decodes what it prints.

struct Snapshot: Decodable {
    var sessions: Int
    var changes: Int
    var imports: Int
    var missing: Int
    var warnings: [String]
    var lastRun: LastRun?
    var accounts: [Account]
    var projects: [Project]
    var terminal: [TerminalGroup]

    struct LastRun: Decodable {
        var at: Double
        var changes: Int
        var date: Date { Date(timeIntervalSince1970: at / 1000) }
    }

    struct Account: Decodable {
        var key: String
        var uuid: String
        var gateway: Bool
        var name: String
        var email: String
        var remark: String
        var signedIn: Bool
        var have: Int
        var add: Int
        var update: Int
        var remove: Int

        enum CodingKeys: String, CodingKey {
            case key, gateway, name, email, remark, signedIn, have, add, update, remove
            case uuid = "id"
        }

        var shortID: String { String(uuid.prefix(8)) }
        var after: Int { have + add - remove }
    }

    struct Project: Decodable {
        var path: String
        var name: String
        var count: Int
        var latest: Double
        var on: Bool
        var from: [Origin]
    }

    struct Origin: Decodable {
        var name: String
        var count: Int
    }

    struct TerminalGroup: Decodable {
        var path: String
        var name: String
        var count: Int
        var latest: Double
        var on: Bool
    }

    /// Accounts whose sidebar is missing sessions.
    var behind: [Account] { accounts.filter { $0.add > 0 || $0.remove > 0 } }
}

struct EngineError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

enum Engine {
    static func call(_ args: [String]) throws -> String {
        guard let runner = Bundle.main.url(forResource: "run", withExtension: "sh") else {
            throw EngineError(message: "程序包不完整：找不到 run.sh，请重新打包")
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [runner.path] + args
        let out = Pipe()
        let err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(decoding: o, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard p.terminationStatus == 0 else {
            let msg = String(decoding: e, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw EngineError(message: msg.isEmpty ? "出错了（退出码 \(p.terminationStatus)）" : msg)
        }
        return text
    }

    static func run(_ args: [String]) async throws -> String {
        try await Task.detached { try call(args) }.value
    }

    static func state() async throws -> Snapshot {
        let json = try await run(["state"])
        return try JSONDecoder().decode(Snapshot.self, from: Data(json.utf8))
    }
}
