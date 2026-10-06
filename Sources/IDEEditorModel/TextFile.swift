import CryptoKit
import Darwin
import Foundation

/// SHA-256, lowercase hex, of a file's bytes: the identity of one version of a file (`DirtyBuffer.baselineHash`).
public enum ContentHash {
    public static func of(_ bytes: some DataProtocol) -> String {
        hex(SHA256.hash(data: bytes))
    }

    /// The hash of `text` encoded as UTF-8, which for a file that decoded as UTF-8 is the hash of its bytes.
    public static func of(text: String) -> String {
        var text = text
        text.makeContiguousUTF8()
        // A contiguous UTF-8 string always provides its storage.
        let digest = text.utf8.withContiguousStorageIfAvailable { SHA256.hash(data: UnsafeRawBufferPointer($0)) }!
        return hex(digest)
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// One version of a text file: its UTF-8 text and the hash of its bytes.
public struct TextSnapshot: Equatable, Sendable {
    public let text: String
    public let hash: String
    /// `text.utf16.count`: what an `NSString` holding the text reports as its length.
    public let utf16Count: Int

    public init(text: String) {
        self.init(text: text, hash: ContentHash.of(text: text))
    }

    init(text: String, hash: String) {
        self.text = text
        self.hash = hash
        utf16Count = text.utf16.count
    }
}

/// Why a file does not open as editable text.
public enum UnsupportedReason: Equatable, Sendable {
    /// Larger than `TextFile.sizeLimit`.
    case tooLarge(bytes: Int)
    /// Contains NUL bytes or is not valid UTF-8.
    case binary
    case directory
    /// The file could not be read (permissions, I/O error): the message says why.
    case unreadable(String)
}

/// What is at a path, as the editor sees it.
public enum FileContents: Equatable, Sendable {
    case text(TextSnapshot)
    case missing
    case unsupported(UnsupportedReason)
}

/// What `stat` says about the file at a path now: the same stamp twice means nothing wrote, replaced or removed the file
/// in between, so it need not be read again.
public struct FileStamp: Equatable, Sendable {
    private var device: Int32
    private var inode: UInt64
    private var size: Int64
    private var modified: timespec
    private var changed: timespec

    /// The stamp of `path`; nil when there is nothing there.
    public init?(path: String) {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        device = info.st_dev
        inode = info.st_ino
        size = info.st_size
        modified = info.st_mtimespec
        changed = info.st_ctimespec
    }

    public static func == (lhs: FileStamp, rhs: FileStamp) -> Bool {
        lhs.device == rhs.device && lhs.inode == rhs.inode && lhs.size == rhs.size
            && lhs.modified.tv_sec == rhs.modified.tv_sec && lhs.modified.tv_nsec == rhs.modified.tv_nsec
            && lhs.changed.tv_sec == rhs.changed.tv_sec && lhs.changed.tv_nsec == rhs.changed.tv_nsec
    }
}

/// Reading and saving text files.
public enum TextFile {
    /// Files larger than this open as a read-only notice instead of text.
    public static let sizeLimit = 10 * 1024 * 1024

    public struct WriteError: Error, CustomStringConvertible {
        public var path: String
        public var operation: String
        public var errno: Int32
        public var description: String { "\(operation) \(path): \(String(cString: strerror(errno)))" }
    }

    /// The file at `path`. UTF-8 without NUL bytes is text (a byte order mark stays part of the text, so the text
    /// hashes like the file); anything else, or anything larger than `sizeLimit`, is unsupported.
    public static func read(_ path: String, sizeLimit: Int = sizeLimit) -> FileContents {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else {
            return errno == ENOENT || errno == ENOTDIR ? .missing : .unsupported(.unreadable(String(cString: strerror(errno))))
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { return .unsupported(.unreadable(String(cString: strerror(errno)))) }
        if info.st_mode & S_IFMT == S_IFDIR { return .unsupported(.directory) }
        if info.st_size > sizeLimit { return .unsupported(.tooLarge(bytes: Int(info.st_size))) }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(Int(info.st_size))
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                return .unsupported(.unreadable(String(cString: strerror(errno))))
            }
            bytes += chunk[..<count]
            // The file grew past the limit while being read.
            if bytes.count > sizeLimit { return .unsupported(.tooLarge(bytes: bytes.count)) }
        }
        if bytes.contains(0) { return .unsupported(.binary) }
        // Decoding repairs invalid sequences; the text is the file only when nothing needed repairing.
        let text = String(decoding: bytes, as: UTF8.self)
        guard text.utf8.elementsEqual(bytes) else { return .unsupported(.binary) }
        return .text(TextSnapshot(text: text, hash: ContentHash.of(bytes)))
    }

    /// Writes `text` as UTF-8 to `path` and returns the version now on disk.
    ///
    /// The file is replaced atomically: the text goes to a hidden temp file next to it, which gets the original's
    /// permissions (mode, ACL, extended attributes), is flushed with `F_FULLFSYNC` and renamed over it; the directory
    /// is flushed last. A symlink is followed, so the file it points to is replaced, not the link. When the directory
    /// does not allow the temp file but the file itself is writable, the file is overwritten in place instead.
    @discardableResult
    public static func write(_ text: String, to path: String) throws -> TextSnapshot {
        let snapshot = TextSnapshot(text: text)
        let target = resolvedTarget(of: path)
        let directory = (target as NSString).deletingLastPathComponent
        let name = (target as NSString).lastPathComponent
        var original = stat()
        let exists = stat(target, &original) == 0
        // A read-only file stays read-only: replacing it through the directory would bypass that.
        if exists, access(target, W_OK) != 0 { throw WriteError(path: target, operation: "writing", errno: errno) }
        let temp = (directory as NSString).appendingPathComponent(".\(name).lantern-\(UUID().uuidString.prefix(8)).tmp")

        // 0666 before the umask for a new file, like any editor creating one; an existing file's mode is copied below.
        let fd = open(temp, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, exists ? 0o600 : 0o666)
        guard fd >= 0 else {
            let error = errno
            if exists, error == EACCES || error == EPERM || error == EROFS, access(target, W_OK) == 0 {
                try overwriteInPlace(text, at: target)
                return snapshot
            }
            throw WriteError(path: temp, operation: "creating", errno: error)
        }
        var renamed = false
        defer {
            if !renamed { unlink(temp) }
        }
        do {
            defer { close(fd) }
            if exists {
                guard fchmod(fd, original.st_mode & 0o7777) == 0 else {
                    throw WriteError(path: temp, operation: "setting permissions of", errno: errno)
                }
                // ACL and extended attributes (Finder tags, quarantine, …) when the file has any; best effort.
                let source = open(target, O_RDONLY | O_CLOEXEC)
                if source >= 0 {
                    _ = fcopyfile(source, fd, nil, copyfile_flags_t(COPYFILE_ACL | COPYFILE_XATTR))
                    close(source)
                }
            }
            try writeAll(text, to: fd, path: temp)
            try fullSync(fd, path: temp)
        }
        guard rename(temp, target) == 0 else { throw WriteError(path: target, operation: "replacing", errno: errno) }
        renamed = true
        syncDirectory(directory)
        return snapshot
    }

    /// `path`, or for a symlink the file it resolves to.
    private static func resolvedTarget(of path: String) -> String {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFLNK,
              let resolved = realpath(path, nil)
        else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func overwriteInPlace(_ text: String, at path: String) throws {
        let fd = open(path, O_WRONLY | O_TRUNC | O_CLOEXEC)
        guard fd >= 0 else { throw WriteError(path: path, operation: "opening", errno: errno) }
        defer { close(fd) }
        try writeAll(text, to: fd, path: path)
        try fullSync(fd, path: path)
    }

    private static func writeAll(_ text: String, to fd: Int32, path: String) throws {
        var text = text
        text.makeContiguousUTF8()
        try text.utf8.withContiguousStorageIfAvailable { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw WriteError(path: path, operation: "writing", errno: errno)
                }
                offset += written
            }
        }
    }

    /// `F_FULLFSYNC` flushes the drive's cache too; volumes that do not support it get `fsync`.
    private static func fullSync(_ fd: Int32, path: String) throws {
        if fcntl(fd, F_FULLFSYNC) == 0 { return }
        guard fsync(fd) == 0 else { throw WriteError(path: path, operation: "flushing", errno: errno) }
    }

    /// Makes the rename durable. The file is already written; a failure here only weakens durability.
    private static func syncDirectory(_ directory: String) {
        let fd = open(directory, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return }
        _ = fsync(fd)
        close(fd)
    }
}
