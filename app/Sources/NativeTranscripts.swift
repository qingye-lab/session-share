import Foundation

struct NativeTranscript {
    var cli: String
    var cwd: String
    var title: String
    var created: Double
    var latest: Double
    var project: String { NativeIO.project(cwd) }
    var cache: JSONObject { ["cwd": cwd, "title": title, "createdAt": created, "lastActivityAt": latest] }
}

enum NativeTranscripts {
    private static let headBytes = 256 * 1024
    private static let tailBytes = 64 * 1024
    private static let chunkBytes = 4 * 1024 * 1024

    static func timestamp(_ value: Any?) -> Double? {
        guard let text = value as? String else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = f.date(from: text) { return date.timeIntervalSince1970 * 1000 }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: text).map { $0.timeIntervalSince1970 * 1000 }
    }

    static func userText(_ d: JSONObject) -> String? {
        guard d["type"] as? String == "user", d["isMeta"] as? Bool != true, d["isSidechain"] as? Bool != true,
              let m = d["message"] as? JSONObject else { return nil }
        let content = m["content"]
        let text = (content as? String) ?? (content as? [JSONObject])?.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined(separator: "\n") ?? ""
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty || t.hasPrefix("<") ? nil : t
    }

    static func read(_ file: URL) throws -> NativeTranscript? {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        try handle.seek(toOffset: 0)
        let head = try handle.read(upToCount: headBytes) ?? Data()
        var cwd: String?, entry: String?, first: String?, start: Double?, end: Double?
        for line in head.split(separator: 10) {
            guard let d = NativeIO.json(Data(line)) else { continue }
            cwd = cwd ?? d["cwd"] as? String
            entry = entry ?? d["entrypoint"] as? String
            first = first ?? userText(d)
            start = start ?? timestamp(d["timestamp"])
        }
        guard let cwd, !cwd.isEmpty, let first, entry != "claude-desktop" else { return nil }
        try handle.seek(toOffset: size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0)
        let tail = try handle.read(upToCount: tailBytes) ?? Data()
        for line in tail.split(separator: 10) {
            if let d = NativeIO.json(Data(line)), let ts = timestamp(d["timestamp"]) { end = ts }
        }
        // Only title lines are parsed in the full stream; assistant payloads may
        // be huge. Keep at most a partial title line between chunks.
        try handle.seek(toOffset: 0)
        var carry = Data(), aiTitle: String?, customTitle: String?
        let markers = [Data("\"ai-title\"".utf8), Data("\"custom-title\"".utf8)]
        func title(_ line: Data) {
            guard markers.contains(where: { line.range(of: $0) != nil }), let d = NativeIO.json(line) else { return }
            if d["type"] as? String == "ai-title", let t = d["aiTitle"] as? String, !t.isEmpty { aiTitle = t }
            if d["type"] as? String == "custom-title", let t = d["customTitle"] as? String, !t.isEmpty { customTitle = t }
        }
        var skippingLongLine = false
        while let chunk = try handle.read(upToCount: chunkBytes), !chunk.isEmpty {
            var data = carry
            data.append(chunk)
            var startIndex = data.startIndex
            if skippingLongLine {
                guard let newline = data.firstIndex(of: 10) else { carry = Data(); continue }
                startIndex = data.index(after: newline)
                skippingLongLine = false
            }
            while startIndex < data.endIndex, let newline = data[startIndex...].firstIndex(of: 10) {
                let line = data[startIndex..<newline]
                if line.count < 1024 * 1024 { title(Data(line)) }
                startIndex = data.index(after: newline)
            }
            carry = Data(data[startIndex...])
            if carry.count > 1024 * 1024 { carry = Data(); skippingLongLine = true }
        }
        if !skippingLongLine { title(carry) }
        let fallback = first.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return NativeTranscript(cli: file.deletingPathExtension().lastPathComponent, cwd: cwd,
                                title: customTitle ?? aiTitle ?? String(fallback.prefix(50)),
                                created: start ?? end ?? NativeIO.now(), latest: end ?? start ?? NativeIO.now())
    }

    static func scan(_ paths: NativePaths) throws -> [NativeTranscript] {
        let cacheFile = paths.state.appendingPathComponent("terminal-cache.json")
        let cache = NativeIO.read(cacheFile) ?? [:]
        var next: JSONObject = [:], result: [NativeTranscript] = []
        for dir in NativeIO.list(paths.projects) {
            let folder = paths.projects.appendingPathComponent(dir)
            guard NativeIO.directory(folder) else { continue }
            for name in NativeIO.list(folder) where name.hasSuffix(".jsonl") {
                let file = folder.appendingPathComponent(name)
                guard !NativeIO.isLink(file), let attrs = try? NativeIO.fm.attributesOfItem(atPath: file.path),
                      let size = attrs[.size] as? NSNumber else { continue }
                let mtime = NativeIO.millis(file)
                var hit = cache[file.path] as? JSONObject
                if (hit?["size"] as? NSNumber) != size || abs((hit?["mtimeMs"] as? Double ?? -1) - mtime) > 0.01 {
                    let t = try? read(file)
                    hit = ["size": size, "mtimeMs": mtime, "info": t?.cache ?? NSNull()]
                }
                next[file.path] = hit
                if let info = hit?["info"] as? JSONObject, let cwd = info["cwd"] as? String,
                   let title = info["title"] as? String, let start = info["createdAt"] as? Double,
                   let end = info["lastActivityAt"] as? Double {
                    result.append(.init(cli: String(name.dropLast(6)), cwd: cwd, title: title, created: start, latest: end))
                }
            }
        }
        if !(NSDictionary(dictionary: next).isEqual(to: cache)) { try NativeIO.writeJSON(cacheFile, next) }
        return result
    }
}
