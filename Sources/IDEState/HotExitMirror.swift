import CryptoKit
import Darwin
import Foundation

/// Plain-file copies of dirty buffers, `hot-exit/<sha256(path)>`: one JSON header line
/// (`{"baselineHash":…,"path":…,"updatedAt":…}`) followed by the buffer's text verbatim. They keep unsaved edits when
/// `state.sqlite` is lost or corrupt, and stay greppable. Each write replaces the file atomically and durably.
enum HotExitMirror {
    private struct Header: Codable {
        var path: String
        var baselineHash: String?
        /// `Date.timeIntervalSinceReferenceDate`, which round-trips a `Date` exactly.
        var updatedAt: Double
    }

    static func fileName(for path: String) -> String {
        SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func url(for path: String, in directory: URL) -> URL {
        directory.appending(path: fileName(for: path), directoryHint: .notDirectory)
    }

    static func encode(_ buffer: DirtyBuffer) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let header = Header(
            path: buffer.path, baselineHash: buffer.baselineHash, updatedAt: buffer.updatedAt.timeIntervalSinceReferenceDate)
        var data = try encoder.encode(header)
        data.append(UInt8(ascii: "\n"))
        data.append(contentsOf: buffer.contents.utf8)
        return data
    }

    static func decode(_ data: Data) -> DirtyBuffer? {
        guard let newline = data.firstIndex(of: UInt8(ascii: "\n")),
              let header = try? JSONDecoder().decode(Header.self, from: data[..<newline])
        else { return nil }
        return DirtyBuffer(
            path: header.path, contents: String(decoding: data[data.index(after: newline)...], as: UTF8.self),
            baselineHash: header.baselineHash, updatedAt: Date(timeIntervalSinceReferenceDate: header.updatedAt))
    }

    static func write(_ buffer: DirtyBuffer, in directory: URL) throws {
        try FileIO.createPrivateDirectory(directory)
        try FileIO.writeAtomically(encode(buffer), to: url(for: buffer.path, in: directory))
    }

    static func remove(path: String, in directory: URL) throws {
        try FileIO.removeDurably(url(for: path, in: directory))
    }

    /// Every mirror in `directory`. Files that are not mirrors (temp files, a header that does not parse, a name that
    /// is not the hash of the header's path) are left alone and skipped.
    static func loadAll(in directory: URL) -> [DirtyBuffer] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []
        return names.sorted().compactMap { name -> DirtyBuffer? in
            guard name.count == 64, name.allSatisfy(\.isHexDigit) else { return nil }
            let file = directory.appending(path: name, directoryHint: .notDirectory)
            guard let data = FileManager.default.contents(atPath: file.path(percentEncoded: false)),
                  let buffer = decode(data), fileName(for: buffer.path) == name
            else {
                stateLog.error("ignoring unreadable hot-exit file \(file.path(percentEncoded: false), privacy: .public)")
                return nil
            }
            return buffer
        }
    }

    /// How long a temp file must have been left alone to count as abandoned: a mirror write takes milliseconds, so one
    /// untouched this long belongs to no write in progress, in this app or in another copy of it on the same data.
    static let abandonedAfter: TimeInterval = 60

    /// Temp files of mirror writes (`.<sha256>.tmp`, `FileIO.writeAtomically`) untouched for `abandonedAfter` before
    /// `now`, with their bytes on disk: what a crash or power loss in the middle of a write left. Nothing reads them.
    static func abandonedWrites(in directory: URL, now: Date = Date()) -> [(url: URL, bytes: Int64)] {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .totalFileAllocatedSizeKey, .isRegularFileKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))) ?? []
        return files.compactMap { url -> (url: URL, bytes: Int64)? in
            let name = url.lastPathComponent
            guard name.hasPrefix("."), name.hasSuffix(".tmp") else { return nil }
            let mirror = name.dropFirst().dropLast(".tmp".count)
            guard mirror.count == 64, mirror.allSatisfy(\.isHexDigit),
                  let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true,
                  let modified = values.contentModificationDate, now.timeIntervalSince(modified) >= abandonedAfter
            else { return nil }
            return (url, Int64(values.totalFileAllocatedSize ?? 0))
        }
    }
}

/// POSIX file primitives for durable writes.
enum FileIO {
    struct Failure: Error, CustomStringConvertible {
        var operation: String
        var path: String
        var code: Int32

        var description: String { "\(operation) \(path): \(String(cString: strerror(code)))" }
    }

    /// Creates `directory` (and missing parents) with mode 0700; an existing directory is left as it is.
    static func createPrivateDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    /// Forces mode 0600 on `url`. A missing file is created empty when `create`, else skipped.
    static func makePrivate(_ url: URL, create: Bool) throws {
        let path = url.path(percentEncoded: false)
        let fd = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | (create ? O_CREAT : 0), 0o600)
        guard fd >= 0 else {
            if !create && errno == ENOENT { return }
            throw Failure(operation: "open", path: path, code: errno)
        }
        defer { close(fd) }
        if fchmod(fd, 0o600) == -1 { throw Failure(operation: "fchmod", path: path, code: errno) }
    }

    /// Replaces `url` atomically and durably: a hidden 0600 temp file next to it is written and flushed with
    /// `F_FULLFSYNC`, renamed over `url`, and the directory is flushed. A crash leaves the old or the new file.
    static func writeAtomically(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        let temporary = directory.appending(path: ".\(url.lastPathComponent).tmp", directoryHint: .notDirectory)
        let temporaryPath = temporary.path(percentEncoded: false)
        let fd = Darwin.open(temporaryPath, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure(operation: "open", path: temporaryPath, code: errno) }
        do {
            // A leftover temp file keeps its old mode through O_CREAT.
            if fchmod(fd, 0o600) == -1 { throw Failure(operation: "fchmod", path: temporaryPath, code: errno) }
            try writeAll(fd, data, path: temporaryPath)
            try fullSync(fd, path: temporaryPath)
        } catch {
            close(fd)
            unlink(temporaryPath)
            throw error
        }
        close(fd)
        let path = url.path(percentEncoded: false)
        guard Darwin.rename(temporaryPath, path) == 0 else {
            let failure = Failure(operation: "rename", path: path, code: errno)
            unlink(temporaryPath)
            throw failure
        }
        try syncDirectory(directory)
    }

    /// Removes `url` if it exists and flushes its directory so the removal survives power loss.
    static func removeDurably(_ url: URL) throws {
        let path = url.path(percentEncoded: false)
        guard unlink(path) == 0 else {
            if errno == ENOENT { return }
            throw Failure(operation: "unlink", path: path, code: errno)
        }
        try syncDirectory(url.deletingLastPathComponent())
    }

    private static func writeAll(_ fd: Int32, _ data: Data, path: String) throws {
        try data.withUnsafeBytes { raw in
            guard var cursor = raw.baseAddress else { return }
            var remaining = raw.count
            while remaining > 0 {
                let written = Darwin.write(fd, cursor, remaining)
                if written > 0 {
                    cursor += written
                    remaining -= written
                } else if written == 0 {
                    throw Failure(operation: "write", path: path, code: EIO)
                } else if errno != EINTR {
                    throw Failure(operation: "write", path: path, code: errno)
                }
            }
        }
    }

    /// `fsync(2)` alone leaves the data in the drive's volatile cache on macOS; `F_FULLFSYNC` flushes it too. Volumes
    /// that reject `F_FULLFSYNC` get a plain `fsync`.
    private static func fullSync(_ fd: Int32, path: String) throws {
        while fcntl(fd, F_FULLFSYNC) == -1 {
            if errno == EINTR { continue }
            while fsync(fd) == -1 {
                if errno != EINTR { throw Failure(operation: "fsync", path: path, code: errno) }
            }
            return
        }
    }

    private static func syncDirectory(_ directory: URL) throws {
        let path = directory.path(percentEncoded: false)
        let fd = Darwin.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw Failure(operation: "open", path: path, code: errno) }
        defer { close(fd) }
        try fullSync(fd, path: path)
    }
}
