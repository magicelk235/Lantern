import Darwin
import Foundation
import os

/// Failure of the daemon's on-disk storage (manifest, ownership locks, `$APP_SUPPORT` layout).
public enum StorageError: Error, Sendable, Equatable, CustomStringConvertible {
    /// A system call failed; `code` is its `errno`.
    case system(operation: String, path: String, code: Int32)

    public var description: String {
        switch self {
        case .system(let operation, let path, let code):
            "\(operation) \(path): \(String(cString: strerror(code))) (errno \(code))"
        }
    }
}

/// Thin POSIX layer shared by the storage types: explicit fds, `pread`/`write` loops, and flushes that reach
/// stable storage.
enum StorageIO {
    static let log = Logger(subsystem: "com.magicelklabs.lantern.ompd", category: "storage")

    static func displayPath(_ url: URL) -> String { url.path(percentEncoded: false) }

    static func failure(_ operation: String, _ url: URL, code: Int32) -> StorageError {
        .system(operation: operation, path: displayPath(url), code: code)
    }

    /// Runs `body` on `url`'s file-system path and returns its result with the `errno` observed right after it.
    static func withPath<T>(_ url: URL, _ body: (UnsafePointer<CChar>) -> T) -> (result: T, code: Int32)? {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return nil }
            let result = body(path)
            return (result, errno)
        }
    }

    /// `open(2)` with `O_CLOEXEC`, retrying `EINTR`. New files get `mode`.
    static func open(_ url: URL, _ flags: Int32, mode: mode_t = 0o600) throws -> Int32 {
        while true {
            guard let (fd, code) = withPath(url, { Darwin.open($0, flags | O_CLOEXEC, mode) }) else {
                throw failure("open", url, code: EINVAL)
            }
            if fd >= 0 { return fd }
            if code != EINTR { throw failure("open", url, code: code) }
        }
    }

    static func close(_ fd: Int32) {
        _ = Darwin.close(fd)
    }

    static func fileSize(_ fd: Int32, _ url: URL) throws -> Int64 {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw failure("fstat", url, code: errno) }
        return Int64(info.st_size)
    }

    /// Reads exactly `count` bytes at `offset`; running into end-of-file is an error.
    static func read(_ fd: Int32, count: Int, at offset: Int64, _ url: URL) throws -> Data {
        guard count > 0 else { return Data() }
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            var done = 0
            while done < count {
                let n = Darwin.pread(fd, base + done, count - done, off_t(offset) + off_t(done))
                if n > 0 {
                    done += n
                } else if n == 0 {
                    throw failure("pread (unexpected end of file)", url, code: EIO)
                } else if errno != EINTR {
                    throw failure("pread", url, code: errno)
                }
            }
        }
        return data
    }

    /// Reads the whole file, or returns nil when it does not exist.
    static func readFileIfPresent(_ url: URL) throws -> Data? {
        let fd: Int32
        do {
            fd = try open(url, O_RDONLY)
        } catch StorageError.system(_, _, let code) where code == ENOENT {
            return nil
        }
        defer { close(fd) }
        return try read(fd, count: Int(fileSize(fd, url)), at: 0, url)
    }

    /// `write(2)` until every byte is written (the fd's offset, or end of file for `O_APPEND`).
    static func write(_ fd: Int32, _ data: Data, _ url: URL) throws {
        try data.withUnsafeBytes { raw in
            guard var cursor = raw.baseAddress else { return }
            var remaining = raw.count
            while remaining > 0 {
                let n = Darwin.write(fd, cursor, remaining)
                if n > 0 {
                    cursor += n
                    remaining -= n
                } else if n == 0 {
                    throw failure("write", url, code: EIO)
                } else if errno != EINTR {
                    throw failure("write", url, code: errno)
                }
            }
        }
    }

    static func truncate(_ fd: Int32, to length: Int64, _ url: URL) throws {
        while ftruncate(fd, off_t(length)) == -1 {
            if errno != EINTR { throw failure("ftruncate", url, code: errno) }
        }
    }

    /// Flushes `fd` to stable storage. On macOS `fsync(2)` only hands the data to the drive, whose volatile cache
    /// can still lose it on power loss; `F_FULLFSYNC` also flushes that cache (measured ~3–4 ms on Apple SSDs, so
    /// it is reserved for durability boundaries). Volumes that reject `F_FULLFSYNC` fall back to `fsync`.
    static func fullSync(_ fd: Int32, _ url: URL) throws {
        while fcntl(fd, F_FULLFSYNC) == -1 {
            if errno == EINTR { continue }
            while fsync(fd) == -1 {
                if errno != EINTR { throw failure("fsync", url, code: errno) }
            }
            return
        }
    }

    /// Makes a directory entry change (create/rename) inside `directory` durable.
    static func syncDirectory(_ directory: URL) throws {
        let fd = try open(directory, O_RDONLY | O_DIRECTORY)
        defer { close(fd) }
        try fullSync(fd, directory)
    }

    /// Creates `directory` (and missing parents) with mode 0700; leaves an existing one untouched.
    static func createDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
    }

    /// Creates `directory` if needed and forces its mode to 0700 even if it already existed.
    static func createPrivateDirectory(_ directory: URL) throws {
        try createDirectory(directory)
        guard let (result, code) = withPath(directory, { chmod($0, 0o700) }) else {
            throw failure("chmod", directory, code: EINVAL)
        }
        if result == -1 { throw failure("chmod", directory, code: code) }
    }

    /// Replaces `url` atomically: write `<name>.tmp` (mode `mode`), flush, `rename(2)` over `url`, flush the
    /// directory. A crash leaves either the old or the new file; a stale `.tmp` is never read and is overwritten
    /// by the next write. `durable: false` skips both flushes (atomic, not power-loss durable).
    static func writeAtomically(_ data: Data, to url: URL, mode: mode_t = 0o600, durable: Bool) throws {
        let directory = url.deletingLastPathComponent()
        let temporary = directory.appending(path: url.lastPathComponent + ".tmp", directoryHint: .notDirectory)
        let fd = try open(temporary, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, mode: mode)
        do {
            // A leftover temp file keeps its old mode through O_CREAT; force ours.
            if fchmod(fd, mode) == -1 { throw failure("fchmod", temporary, code: errno) }
            try write(fd, data, temporary)
            if durable { try fullSync(fd, temporary) }
        } catch {
            close(fd)
            _ = withPath(temporary) { unlink($0) }
            throw error
        }
        close(fd)
        let renamed = temporary.withUnsafeFileSystemRepresentation { from in
            url.withUnsafeFileSystemRepresentation { to -> Int32 in
                guard let from, let to else { return EINVAL }
                return Darwin.rename(from, to) == 0 ? 0 : errno
            }
        }
        if renamed != 0 {
            _ = withPath(temporary) { unlink($0) }
            throw failure("rename", url, code: renamed)
        }
        if durable { try syncDirectory(directory) }
    }
}
