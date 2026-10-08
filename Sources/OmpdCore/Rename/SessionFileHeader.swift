import Darwin
import Foundation

/// The session header of an omp session file (`{"type":"session",…}`, its first line or the one after omp's title slot)
/// rewritten in place of the file: atomically (a copy beside it renamed over it), with the file's mode and dates kept,
/// every other byte as it was.
enum SessionFileHeader {
    /// The header of the session file at `path`; nil when it has none (a file of something else, or cut short).
    static func read(_ path: String) throws -> JSONObjectLine? {
        guard let handle = FileHandle(forReadingAtPath: path) else { throw StorageError.system(operation: "open", path: path, code: errno) }
        defer { try? handle.close() }
        return try locate(in: handle)?.header
    }

    /// Applies `change` to the header of the session file at `path` and writes the file back when it changed anything.
    /// False when the file has no header or nothing changed.
    @discardableResult
    static func rewrite(_ path: String, _ change: (inout JSONObjectLine) -> Void) throws -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { throw StorageError.system(operation: "open", path: path, code: errno) }
        defer { try? handle.close() }
        guard let found = try locate(in: handle) else { return false }
        var header = found.header
        change(&header)
        guard header.text != found.header.text else { return false }

        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0 else { throw StorageError.system(operation: "fstat", path: path, code: errno) }
        let url = URL(filePath: path)
        let temporary = url.deletingLastPathComponent().appending(path: ".\(url.lastPathComponent).rename-tmp").path(percentEncoded: false)
        let fd = Darwin.open(temporary, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw StorageError.system(operation: "open", path: temporary, code: errno) }
        let output = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            var head = found.prefix
            head.replaceSubrange(found.line, with: Data(header.text.utf8))
            try output.write(contentsOf: head)
            try handle.seek(toOffset: UInt64(found.prefix.count))
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                try output.write(contentsOf: chunk)
            }
            guard fcntl(fd, F_FULLFSYNC) == 0 || fsync(fd) == 0 else { throw StorageError.system(operation: "fsync", path: temporary, code: errno) }
            _ = fchmod(fd, info.st_mode & 0o7777)
            var times = [info.st_atimespec, info.st_mtimespec]
            _ = futimens(fd, &times)
            try output.close()
            guard Darwin.rename(temporary, path) == 0 else { throw StorageError.system(operation: "rename", path: path, code: errno) }
        } catch {
            try? output.close()
            unlink(temporary)
            throw error
        }
        return true
    }

    /// The header line within the file's start: the bytes read (whole lines up to and including the header's), the
    /// header line's range in them (without its newline), the header.
    private static func locate(in handle: FileHandle) throws -> (prefix: Data, line: Range<Int>, header: JSONObjectLine)? {
        var prefix = Data()
        var lineStart = 0
        var lineIndex = 0
        // omp writes the header as the first line, or as the second after the title slot.
        while lineIndex < 2 {
            let newline = prefix[lineStart...].firstIndex(of: UInt8(ascii: "\n"))
            guard let newline else {
                guard prefix.count < 8 << 20, let chunk = try handle.read(upToCount: 64 << 10), !chunk.isEmpty else { return nil }
                prefix.append(chunk)
                continue
            }
            let line = lineStart..<newline
            if let object = JSONObjectLine(String(decoding: prefix[line], as: UTF8.self)) {
                if object.string("type") == "session" {
                    return (prefix.prefix(newline + 1), line, object)
                }
                guard lineIndex == 0, object.string("type") == "title" else { return nil }
            } else {
                return nil
            }
            lineStart = newline + 1
            lineIndex += 1
        }
        return nil
    }
}

/// A one-line JSON object whose members keep their order and their text: what is not changed is written back as it
/// was read.
struct JSONObjectLine: Equatable {
    private struct Member: Equatable {
        var key: String
        var rawKey: String
        var rawValue: String
    }

    private var members: [Member]

    /// nil when `line` is not one JSON object.
    init?(_ line: String) {
        let bytes = Array(line.utf8)
        var scanner = Scanner(bytes: bytes)
        guard let members = scanner.object(), scanner.atEnd else { return nil }
        self.members = members.map { Member(key: $0.key, rawKey: $0.rawKey, rawValue: $0.rawValue) }
    }

    var text: String {
        "{" + members.map { "\($0.rawKey):\($0.rawValue)" }.joined(separator: ",") + "}"
    }

    func string(_ key: String) -> String? {
        value(key) as? String
    }

    func strings(_ key: String) -> [String]? {
        (value(key) as? [Any])?.compactMap { $0 as? String }
    }

    mutating func set(_ key: String, _ value: String) {
        set(key, raw: Self.encode(value))
    }

    mutating func set(_ key: String, _ values: [String]) {
        set(key, raw: Self.encode(values))
    }

    private func value(_ key: String) -> Any? {
        guard let raw = members.first(where: { $0.key == key })?.rawValue else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(raw.utf8), options: .fragmentsAllowed)
    }

    private mutating func set(_ key: String, raw: String) {
        if let index = members.firstIndex(where: { $0.key == key }) {
            members[index].rawValue = raw
        } else {
            members.append(Member(key: key, rawKey: Self.encode(key), rawValue: raw))
        }
    }

    private static func encode(_ value: Any) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes])) ?? Data("null".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// Splits a JSON object into its members' raw text; values are only delimited, decoded on demand.
    private struct Scanner {
        let bytes: [UInt8]
        var index = 0

        var atEnd: Bool {
            var copy = self
            copy.skipSpace()
            return copy.index == bytes.count
        }

        mutating func object() -> [(key: String, rawKey: String, rawValue: String)]? {
            skipSpace()
            guard take(UInt8(ascii: "{")) else { return nil }
            var members: [(key: String, rawKey: String, rawValue: String)] = []
            skipSpace()
            if take(UInt8(ascii: "}")) { return members }
            while true {
                skipSpace()
                let keyStart = index
                guard skipString() else { return nil }
                let rawKey = text(keyStart..<index)
                guard let key = (try? JSONSerialization.jsonObject(with: Data(rawKey.utf8), options: .fragmentsAllowed)) as? String else {
                    return nil
                }
                skipSpace()
                guard take(UInt8(ascii: ":")) else { return nil }
                skipSpace()
                let valueStart = index
                guard skipValue() else { return nil }
                members.append((key, rawKey, text(valueStart..<index)))
                skipSpace()
                if take(UInt8(ascii: ",")) { continue }
                return take(UInt8(ascii: "}")) ? members : nil
            }
        }

        private func text(_ range: Range<Int>) -> String {
            String(decoding: bytes[range], as: UTF8.self)
        }

        private mutating func take(_ byte: UInt8) -> Bool {
            guard index < bytes.count, bytes[index] == byte else { return false }
            index += 1
            return true
        }

        private mutating func skipSpace() {
            while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
        }

        private mutating func skipString() -> Bool {
            guard take(UInt8(ascii: "\"")) else { return false }
            while index < bytes.count {
                switch bytes[index] {
                case UInt8(ascii: "\\"): index += 2
                case UInt8(ascii: "\""):
                    index += 1
                    return true
                default: index += 1
                }
            }
            return false
        }

        private mutating func skipValue() -> Bool {
            guard index < bytes.count else { return false }
            switch bytes[index] {
            case UInt8(ascii: "\""):
                return skipString()
            case UInt8(ascii: "{"), UInt8(ascii: "["):
                var depth = 0
                while index < bytes.count {
                    switch bytes[index] {
                    case UInt8(ascii: "\""):
                        guard skipString() else { return false }
                        continue
                    case UInt8(ascii: "{"), UInt8(ascii: "["): depth += 1
                    case UInt8(ascii: "}"), UInt8(ascii: "]"):
                        depth -= 1
                        if depth == 0 {
                            index += 1
                            return true
                        }
                    default: break
                    }
                    index += 1
                }
                return false
            default:
                let start = index
                while index < bytes.count, ![UInt8(ascii: ","), UInt8(ascii: "}"), UInt8(ascii: "]"), 0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) {
                    index += 1
                }
                return index > start
            }
        }
    }
}
