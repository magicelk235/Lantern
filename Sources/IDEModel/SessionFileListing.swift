import Foundation

/// One omp session file of a workspace, as omp's resume picker reads it (`SessionManager.list`): metadata from the
/// file's first 4 KiB, lifecycle status from its last 32 KiB, never the whole file.
public struct SessionFileInfo: Equatable, Sendable {
    /// How the conversation's last message left it (omp's `SessionInfo.status`).
    public enum Status: String, Sendable {
        /// The assistant answered and asked for nothing more.
        case complete
        /// The last turn stopped mid-way: a tool call without its result, a tool result without an answer, or an
        /// answer cut off at the output limit.
        case interrupted
        /// The user aborted the last answer.
        case aborted
        /// The last answer failed.
        case error
        /// The user's last message has no answer.
        case pending
        /// No message in the tail, or one of another kind.
        case unknown
    }

    /// The `.jsonl` file.
    public var path: String
    /// omp's session id (the header's `id`).
    public var id: String
    /// The folder omp ran in (the header's `cwd`), empty when it records none.
    public var cwd: String
    /// The fixed-width title slot's title, else the header's, else the last compaction summary in the prefix. nil when
    /// the slot holds an empty title (omp then ignores the header's).
    public var title: String?
    /// The first user message's text in the prefix, else the first developer or assistant text; nil without messages.
    public var firstMessage: String?
    /// The header's `timestamp`.
    public var created: Date?
    public var modified: Date
    public var size: Int
    public var status: Status

    /// The title's first line, else the first message's, else "Untitled" (control characters stripped).
    public var displayTitle: String {
        Self.firstLine(title) ?? Self.firstLine(firstMessage) ?? "Untitled"
    }

    /// Every whitespace-separated token of `query` appears (case- and diacritic-insensitively) in the title or the first
    /// message. An empty query matches everything.
    public func matches(_ query: String) -> Bool {
        let haystack = [title, firstMessage].compactMap(\.self).joined(separator: "\n")
        return query.split(whereSeparator: \.isWhitespace).allSatisfy { haystack.localizedStandardContains($0) }
    }

    /// omp's `sanitizeSessionName`: the first line without control characters, trimmed; nil when nothing is left.
    static func firstLine(_ text: String?) -> String? {
        guard let line = text?.split(maxSplits: 1, omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" }).first
        else { return nil }
        let cleaned = String(String.UnicodeScalarView(line.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F }))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }
}

/// Lists the omp session files of a workspace the way omp's `SessionManager.list(cwd)` does: the `*.jsonl` files at
/// the top of the workspace's bucket under `~/.omp/agent/sessions` (subagent transcripts live in a folder per session
/// and are skipped), each read from a 4 KiB prefix and a 32 KiB tail, newest first. Read-only: unlike omp it repairs
/// no orphaned backups and migrates no legacy buckets.
public enum SessionFileListing {
    /// omp's default session store.
    public static var defaultSessionsRoot: URL {
        URL(filePath: home, directoryHint: .isDirectory).appending(path: ".omp/agent/sessions", directoryHint: .isDirectory)
    }

    static let prefixBytes = 4096
    static let tailBytes = 32768

    /// The sessions omp keeps for `workspace` in its bucket under `sessionsRoot`, plus those in `sessionDirectories`
    /// (`--session-dir` folders, which hold every workspace's sessions) whose cwd is the workspace. Newest first; the
    /// paths are canonical (under the folders' `realpath`), as ompd records session files. Reads the files off the
    /// caller's actor.
    public static func list(
        workspace: URL, sessionsRoot: URL = defaultSessionsRoot, sessionDirectories: [URL] = []
    ) async -> [SessionFileInfo] {
        let cwd = canonicalPath(workspace.path(percentEncoded: false))
        let name = bucketName(canonicalCwd: cwd, home: canonicalPath(home), temporaryDirectory: canonicalPath(temporaryDirectory))
        let bucket = canonicalPath(sessionsRoot.appending(path: name).path(percentEncoded: false))
        var sessions = list(directory: URL(filePath: bucket, directoryHint: .isDirectory))
        var seen = Set(sessions.map(\.path))
        for directory in Set(sessionDirectories.map { canonicalPath($0.path(percentEncoded: false)) }) where directory != bucket {
            for session in list(directory: URL(filePath: directory, directoryHint: .isDirectory))
            where !seen.contains(session.path) && canonicalPath(session.cwd) == cwd {
                seen.insert(session.path)
                sessions.append(session)
            }
        }
        return sessions.sorted(by: newestFirst)
    }

    /// The sessions in one folder: its visible top-level `*.jsonl` files that start with an omp session header,
    /// newest first.
    public static func list(directory: URL) -> [SessionFileInfo] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        else { return [] }
        return files
            .filter { $0.pathExtension == "jsonl" }
            .compactMap { file -> SessionFileInfo? in
                guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                      let (prefix, tail) = readSlices(file)
                else { return nil }
                return info(
                    path: file.path(percentEncoded: false), prefix: prefix, tail: tail,
                    modified: values.contentModificationDate ?? .distantPast, size: values.fileSize ?? 0)
            }
            .sorted(by: newestFirst)
    }

    /// omp's order: modified, then created, then path, each descending.
    static func newestFirst(_ a: SessionFileInfo, _ b: SessionFileInfo) -> Bool {
        if a.modified != b.modified { return a.modified > b.modified }
        let (createdA, createdB) = (a.created ?? .distantPast, b.created ?? .distantPast)
        if createdA != createdB { return createdA > createdB }
        return a.path > b.path
    }

    // MARK: - Buckets

    /// omp's bucket for a canonical cwd (`session-paths.ts`): `-<relative>` under the home folder, `-tmp-<relative>`
    /// under the temp folder, else `--<absolute>--`, with `/`, `\` and `:` in the path made `-`. `home` and
    /// `temporaryDirectory` are canonical too.
    public static func bucketName(canonicalCwd cwd: String, home: String, temporaryDirectory: String) -> String {
        if let relative = relativePath(of: cwd, inside: home) {
            return joined("-", relative)
        }
        if let relative = relativePath(of: cwd, inside: temporaryDirectory) {
            return joined("-tmp", relative)
        }
        return "--\(dashed(String(cwd.drop { $0 == "/" || $0 == "\\" })))--"
    }

    /// `path`'s `realpath`, else the path standardized; without a trailing slash. omp buckets and ompd compares session
    /// files by it.
    public static func canonicalPath(_ path: String) -> String {
        let resolved: String
        if let real = realpath(path, nil) {
            resolved = String(cString: real)
            free(real)
        } else {
            resolved = URL(filePath: path).standardizedFileURL.path(percentEncoded: false)
        }
        return resolved.count > 1 && resolved.hasSuffix("/") ? String(resolved.dropLast()) : resolved
    }

    /// Node's `path.relative(base, path)` when it neither climbs out (`..`) nor is absolute; nil otherwise.
    private static func relativePath(of path: String, inside base: String) -> String? {
        let relative: String
        if path == base {
            relative = ""
        } else if base == "/" {
            relative = String(path.dropFirst())
        } else if path.hasPrefix(base + "/") {
            relative = String(path.dropFirst(base.count + 1))
        } else {
            return nil
        }
        return relative.hasPrefix("..") ? nil : relative
    }

    private static func joined(_ prefix: String, _ relative: String) -> String {
        let tail = dashed(relative)
        guard !tail.isEmpty else { return prefix }
        return prefix.hasSuffix("-") ? prefix + tail : "\(prefix)-\(tail)"
    }

    private static func dashed(_ path: String) -> String {
        String(path.map { $0 == "/" || $0 == "\\" || $0 == ":" ? "-" : $0 })
    }

    /// Node's `os.homedir()` and `os.tmpdir()`, which omp buckets by.
    private static var home: String {
        ProcessInfo.processInfo.environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
    }

    private static var temporaryDirectory: String {
        let environment = ProcessInfo.processInfo.environment
        let directory = ["TMPDIR", "TMP", "TEMP"].lazy.compactMap { environment[$0] }.first { !$0.isEmpty } ?? "/tmp"
        return directory.count > 1 && directory.hasSuffix("/") ? String(directory.dropLast()) : directory
    }

    // MARK: - Reading

    /// The file's first 4 KiB and last 32 KiB (overlapping for a small file).
    private static func readSlices(_ file: URL) -> (prefix: Data, tail: Data)? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), (try? handle.seek(toOffset: 0)) != nil,
              let prefix = try? handle.read(upToCount: prefixBytes) ?? Data()
        else { return nil }
        if size <= UInt64(prefixBytes) { return (prefix, prefix.suffix(tailBytes)) }
        let tailCount = min(UInt64(tailBytes), size)
        guard (try? handle.seek(toOffset: size - tailCount)) != nil, let tail = try? handle.read(upToCount: Int(tailCount))
        else { return nil }
        return (prefix, tail)
    }

    /// The session's metadata from its prefix and status from its tail; nil when the prefix starts with no session
    /// header (omp's `buildSessionInfo`).
    static func info(path: String, prefix: Data, tail: Data, modified: Date, size: Int) -> SessionFileInfo? {
        let bytes = Array(prefix)
        let entries = lines(bytes).compactMap(object)
        guard let header = header(bytes, entries: entries) else { return nil }
        var compactionSummary: String?
        var firstUserText: String?
        for entry in entries.dropFirst() {
            if entry["type"] as? String == "compaction", let summary = entry["shortSummary"] as? String {
                compactionSummary = summary
            }
            guard firstUserText == nil, entry["type"] as? String == "message",
                  let message = entry["message"] as? [String: Any], message["role"] as? String == "user",
                  let text = messageText(message["content"]), !text.isEmpty
            else { continue }
            firstUserText = text
        }
        let firstMessage = firstUserText ?? scannedFirstMessage(bytes)
        return SessionFileInfo(
            path: path, id: header.id, cwd: header.cwd ?? "", title: header.title ?? compactionSummary,
            firstMessage: firstMessage.flatMap { $0.isEmpty ? nil : $0 }, created: header.timestamp.flatMap(parseDate),
            modified: modified, size: size, status: status(tail: Array(tail)))
    }

    private struct Header {
        var id: String
        var cwd: String?
        var title: String?
        var timestamp: String?
    }

    /// omp's `parseSessionHeader`: the parsed header (after the title slot, whose non-empty title wins and whose empty
    /// title hides the header's), else the same read by scanning the first lines' text (a header cut off by the 4 KiB
    /// prefix).
    private static func header(_ prefix: [UInt8], entries: [[String: Any]]) -> Header? {
        let first = entries.first
        let hasSlot = first?["type"] as? String == "title"
        let slotTitle = hasSlot ? slot(first?["title"] as? String) : .absent
        if let parsed = entries.dropFirst(hasSlot ? 1 : 0).first,
           parsed["type"] as? String == "session", let id = parsed["id"] as? String {
            return Header(
                id: id, cwd: parsed["cwd"] as? String, title: slotTitle.resolve(parsed["title"] as? String),
                timestamp: parsed["timestamp"] as? String)
        }
        var scannedSlot = SlotTitle.absent
        var isFirst = true
        for line in lines(prefix) {
            let bytes = Array(line.drop(while: isSpace).reversed().drop(while: isSpace).reversed())
            guard !bytes.isEmpty else { continue }
            if isFirst, stringField(bytes, "type") == "title" {
                scannedSlot = slot(stringField(bytes, "title"))
                isFirst = false
                continue
            }
            guard stringField(bytes, "type") == "session", let id = stringField(bytes, "id"), !id.isEmpty else { return nil }
            return Header(
                id: id, cwd: stringField(bytes, "cwd"), title: scannedSlot.resolve(stringField(bytes, "title")),
                timestamp: stringField(bytes, "timestamp"))
        }
        return nil
    }

    private enum SlotTitle {
        case absent, empty, title(String)

        func resolve(_ headerTitle: String?) -> String? {
            switch self {
            case .absent: headerTitle
            case .empty: nil
            case .title(let title): title
            }
        }
    }

    private static func slot(_ title: String?) -> SlotTitle {
        guard let title else { return .absent }
        return title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .empty : .title(title)
    }

    private static func lines(_ bytes: [UInt8]) -> [ArraySlice<UInt8>] {
        bytes.split(separator: UInt8(ascii: "\n"))
    }

    /// A line's JSON object; nil for anything else, such as the prefix's cut-off last line.
    private static func object(_ line: ArraySlice<UInt8>) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
    }

    private static func isSpace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    /// A message's `content` as text: a string as it is, text blocks joined by a space.
    private static func messageText(_ content: Any?) -> String? {
        if let text = content as? String { return text }
        guard let blocks = content as? [[String: Any]] else { return nil }
        return blocks.filter { $0["type"] as? String == "text" }.map { $0["text"] as? String ?? "" }.joined(separator: " ")
    }

    /// omp's text-scan fallback for a first message cut off by the prefix: the first `"role"` that is a user's with a
    /// string `content` or `text` after it, else the first developer's or assistant's.
    private static func scannedFirstMessage(_ bytes: [UInt8]) -> String? {
        let role = Array(#""role""#.utf8)
        var fallback: String?
        var start = find(role, in: bytes, from: 0)
        while let index = start {
            let name = stringField(bytes, "role", from: index)
            if let text = stringField(bytes, "content", from: index) ?? stringField(bytes, "text", from: index), !text.isEmpty {
                if name == "user" { return text }
                if fallback == nil, name == "developer" || name == "assistant" { fallback = text }
            }
            start = find(role, in: bytes, from: index + role.count)
        }
        return fallback
    }

    /// omp's `extractStringField`: the string value after the first `"key"` at or after `from`, read up to its closing
    /// quote or the end of the text; nil when the value is not a string.
    static func stringField(_ bytes: [UInt8], _ key: String, from: Int = 0) -> String? {
        let quoted = Array("\"\(key)\"".utf8)
        guard let keyIndex = find(quoted, in: bytes, from: from),
              let colon = bytes[(keyIndex + quoted.count)...].firstIndex(of: UInt8(ascii: ":"))
        else { return nil }
        var index = colon + 1
        while index < bytes.count, isSpace(bytes[index]) { index += 1 }
        guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { return nil }
        let start = index + 1
        var escaped = false
        for position in start..<bytes.count {
            if escaped {
                escaped = false
            } else if bytes[position] == UInt8(ascii: "\\") {
                escaped = true
            } else if bytes[position] == UInt8(ascii: "\"") {
                return unescape(bytes[start..<position])
            }
        }
        return unescape(bytes[start...])
    }

    /// A JSON string body (without quotes) decoded; a body cut mid-escape falls back to replacing the common escapes.
    private static func unescape(_ body: ArraySlice<UInt8>) -> String {
        var body = Array(body)
        if body.last == UInt8(ascii: "\\") { body.removeLast() }
        if let string = try? JSONSerialization.jsonObject(with: Data([UInt8(ascii: "\"")] + body + [UInt8(ascii: "\"")]), options: .fragmentsAllowed) as? String {
            return string
        }
        return String(decoding: body, as: UTF8.self)
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\r", with: "\r")
            .replacingOccurrences(of: "\\t", with: "\t")
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }

    private static func find(_ needle: [UInt8], in bytes: [UInt8], from: Int) -> Int? {
        guard !needle.isEmpty, from >= 0, bytes.count >= needle.count, from <= bytes.count - needle.count else { return nil }
        var index = from
        while index <= bytes.count - needle.count {
            if bytes[index] == needle[0], bytes[index..<(index + needle.count)].elementsEqual(needle) { return index }
            index += 1
        }
        return nil
    }

    /// omp's `getSessionStatus`: the newest whole `message` line of the tail decides.
    static func status(tail: [UInt8]) -> SessionFileInfo.Status {
        for line in lines(tail).reversed() where line.first == UInt8(ascii: "{") {
            guard let entry = object(line), entry["type"] as? String == "message", let message = entry["message"] as? [String: Any]
            else { continue }
            switch message["role"] as? String {
            case "assistant":
                switch message["stopReason"] as? String {
                case "error": return .error
                case "aborted": return .aborted
                case "length": return .interrupted
                default: break
                }
                let calls = (message["content"] as? [Any])?.contains { ($0 as? [String: Any])?["type"] as? String == "toolCall" }
                return calls == true ? .interrupted : .complete
            case "toolResult": return .interrupted
            case "user": return .pending
            default: return .unknown
            }
        }
        return .unknown
    }

    private static func parseDate(_ timestamp: String) -> Date? {
        (try? Date(timestamp, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
            ?? (try? Date(timestamp, strategy: Date.ISO8601FormatStyle()))
    }
}
