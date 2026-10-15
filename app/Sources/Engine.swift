import Foundation

// Native Swift engine; the Snapshot contract is shared with the menu bar UI.

struct Snapshot: Codable {
    var sessions: Int
    var changes: Int
    var imports: Int
    var missing: Int
    var warnings: [String]
    var lastRun: LastRun?
    var accounts: [Account]
    var projects: [Project]
    var terminal: [TerminalGroup]

    struct LastRun: Codable {
        var at: Double
        var changes: Int
        var date: Date { Date(timeIntervalSince1970: at / 1000) }
    }

    struct Account: Codable {
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

    struct Project: Codable {
        var path: String
        var name: String
        var count: Int
        var latest: Double
        var on: Bool
        var from: [Origin]
    }

    struct Origin: Codable {
        var name: String
        var count: Int
    }

    struct TerminalGroup: Codable {
        var path: String
        var name: String
        var count: Int
        var latest: Double
        var on: Bool
    }

    /// Accounts whose sidebar has pending changes.
    var behind: [Account] { accounts.filter { $0.add > 0 || $0.update > 0 || $0.remove > 0 } }
}

struct EngineError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

enum Engine {
    // One queue for reads and writes, including settings learned during scans.
    private static let queue = DispatchQueue(label: "session-share.engine", qos: .userInitiated)

    static func call(_ args: [String]) throws -> String {
        try queue.sync { try NativeMerge().command(args) }
    }

    static func run(_ args: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try NativeMerge().command(args)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    static func state() async throws -> Snapshot {
        let json = try await run(["state"])
        return try JSONDecoder().decode(Snapshot.self, from: Data(json.utf8))
    }
}
