import Foundation
import CryptoKit
import Darwin

// Shared file operations for the native engine. No external runtime or packages.
typealias JSONObject = [String: Any]

struct NativePaths {
    let home: URL
    var support: URL { home.appendingPathComponent("Library/Application Support") }
    var projects: URL { home.appendingPathComponent(".claude/projects") }
    var state: URL { support.appendingPathComponent("session-share") }

    init(home: URL? = nil) {
        self.home = home ?? ProcessInfo.processInfo.environment["SESSION_SHARE_ROOT"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser
    }
}

enum NativeIO {
    static let fm = FileManager.default
    static let dataDirs = ["Claude", "Claude-3p"]
    static let index = "archived-sessions.idx"

    static func list(_ dir: URL) -> [String] {
        ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }

    static func exists(_ file: URL) -> Bool { fm.fileExists(atPath: file.path) }
    static func directory(_ file: URL) -> Bool {
        var isDir: ObjCBool = false
        return fm.fileExists(atPath: file.path, isDirectory: &isDir) && isDir.boolValue && !isLink(file)
    }
    static func isLink(_ file: URL) -> Bool {
        (try? fm.attributesOfItem(atPath: file.path)[.type] as? FileAttributeType) == .typeSymbolicLink
    }
    static func json(_ data: Data) -> JSONObject? { (try? JSONSerialization.jsonObject(with: data)) as? JSONObject }
    static func read(_ file: URL) -> JSONObject? { (try? Data(contentsOf: file)).flatMap(json) }
    static func encode(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }
    static func millis(_ file: URL) -> Double {
        ((try? fm.attributesOfItem(atPath: file.path)[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0) * 1000
    }
    static func now() -> Double { Date().timeIntervalSince1970 * 1000 }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    static func privateDirectory(_ dir: URL) throws {
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    static func write(_ file: URL, _ body: Data) throws {
        let temp = file.deletingLastPathComponent().appendingPathComponent(".session-share-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: temp) }
        guard fm.createFile(atPath: temp.path, contents: body, attributes: [.posixPermissions: 0o600]) else {
            throw EngineError(message: "无法写入 \(file.path)")
        }
        guard Darwin.rename(temp.path, file.path) == 0 else {
            throw EngineError(message: "无法替换 \(file.path)：\(String(cString: strerror(errno)))")
        }
    }
    static func writeJSON(_ file: URL, _ object: Any) throws { try write(file, encode(object)) }
    static func remove(_ file: URL) throws {
        if exists(file) { try fm.removeItem(at: file) }
    }

    // stderr is a file so a noisy child cannot fill a second pipe and deadlock.
    static func process(_ executable: String, _ arguments: [String], temp: URL) throws -> Data {
        try privateDirectory(temp)
        let errors = temp.appendingPathComponent(".process-\(UUID().uuidString)")
        fm.createFile(atPath: errors.path, contents: nil, attributes: [.posixPermissions: 0o600])
        defer { try? fm.removeItem(at: errors) }
        let err = try FileHandle(forWritingTo: errors)
        defer { try? err.close() }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        let out = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            let msg = (try? String(contentsOf: errors, encoding: .utf8)) ?? ""
            throw EngineError(message: "\(URL(fileURLWithPath: executable).lastPathComponent) 失败：\(msg)")
        }
        return data
    }

    static func project(_ cwd: String?) -> String {
        guard let cwd, !cwd.isEmpty else { return "(未知文件夹)" }
        if let r = cwd.range(of: "/.claude/worktrees/") { return String(cwd[..<r.lowerBound]) }
        return cwd
    }
    static func importID(_ cli: String) -> String {
        var h = Array(Insecure.SHA1.hash(data: Data(("session-share:" + cli).utf8)).map { String(format: "%02x", $0) }.joined())
        h[12] = "5"
        h[16] = Character(String((Int(String(h[16]), radix: 16)! & 3) | 8, radix: 16))
        let s = String(h)
        return "local_" + [s.prefix(8), s.dropFirst(8).prefix(4), s.dropFirst(12).prefix(4), s.dropFirst(16).prefix(4), s.dropFirst(20).prefix(12)].map(String.init).joined(separator: "-")
    }
}

// Serializes commands across app/CLI processes. The OS releases the lock on a
// crash, so a long transcript scan is never mistaken for a stale writer.
final class NativeLock {
    private let fd: Int32
    init(_ state: URL) throws {
        try NativeIO.privateDirectory(state)
        fd = Darwin.open(state.appendingPathComponent(".native-lock").path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw EngineError(message: "无法创建同步锁") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(fd)
            throw EngineError(message: "另一个扫描或合并正在进行，请稍后重试")
        }
        // An older JS version uses a PID file. Do not write alongside it.
        let legacy = state.appendingPathComponent("lock")
        if let text = try? String(contentsOf: legacy, encoding: .utf8), let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), kill(pid, 0) == 0 || errno == EPERM {
            flock(fd, LOCK_UN)
            Darwin.close(fd)
            throw EngineError(message: "旧版会话合并仍在运行，请先退出旧版")
        }
    }
    deinit { flock(fd, LOCK_UN); Darwin.close(fd) }
}
