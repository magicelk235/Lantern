import CryptoKit
import Darwin
import Foundation
import IDEProtocol
import os

/// Naming of session ownership locks: `<ownedSessionsDir>/<sha256(canonicalPath(sessionFile))>.lock`, hex
/// lowercase. The ide-bridge computes the same name (Bun's `fs.realpathSync` agrees with `realpath(3)`, including case
/// canonicalization) and probes it with a shared non-blocking flock.
public enum OwnershipLock {
    public static func lockURL(for sessionFile: String, in ownedSessionsDir: URL) -> URL {
        lockURL(canonicalPath: canonicalPath(sessionFile), in: ownedSessionsDir)
    }

    /// `realpath(3)` of `path`. For a file not on disk yet: `realpath` of its directory plus its name, which is what
    /// `realpath` returns once omp creates the file. `path` unchanged if neither resolves. The bridge uses the same rule.
    public static func canonicalPath(_ path: String) -> String {
        if let resolved = resolve(path) { return resolved }
        let name = (path as NSString).lastPathComponent
        let parent = (path as NSString).deletingLastPathComponent
        guard !name.isEmpty, let directory = resolve(parent.isEmpty ? "." : parent) else { return path }
        return directory == "/" ? "/\(name)" : "\(directory)/\(name)"
    }

    private static func resolve(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    static func lockURL(canonicalPath: String, in ownedSessionsDir: URL) -> URL {
        let hex = SHA256.hash(data: Data(canonicalPath.utf8)).map { String(format: "%02x", $0) }.joined()
        return ownedSessionsDir.appending(path: "\(hex).lock", directoryHint: .notDirectory)
    }
}

/// ompd's claim on one omp session file: `flock(LOCK_EX)` on its ownership lock file, held on an open close-on-exec
/// descriptor until `release()` (or deinit, or ompd's death — the kernel drops the lock, so it never goes stale).
/// omp children never inherit it. The lock body is JSON `{sessionFile, sessionId, sessionKey}`; the bridge reads it to
/// map `omp --resume <id-prefix>` to a file.
public final class OwnedSessionLock: Sendable {
    /// Canonical (`realpath`) session file the lock is named after.
    public let sessionFile: String
    public let lockURL: URL
    private let descriptor: OSAllocatedUnfairLock<Int32>

    /// A lock-mode bridge probes with a momentary shared lock; a few short retries keep that probe from making ompd
    /// believe the session is owned by someone else.
    static let contentionAttempts = 5
    static let contentionBackoffMicroseconds: useconds_t = 10_000

    private struct Body: Encodable {
        let sessionFile: String
        let sessionId: String?
        let sessionKey: SessionKey
    }

    private init(sessionFile: String, lockURL: URL, fd: Int32) {
        self.sessionFile = sessionFile
        self.lockURL = lockURL
        descriptor = OSAllocatedUnfairLock(initialState: fd)
    }

    deinit { release() }

    /// Takes the ownership lock of `sessionFile` in `dir` (created 0700 if missing; normally
    /// `AppSupportPaths.ownedSessions`), then records the body.
    /// - Throws: `BridgeError.alreadyOwned` when another open file description holds the lock (in this or any other
    ///   process); `StorageError` / `BridgeError.system` for I/O failures.
    public static func acquire(sessionFile: String, sessionId: String?, sessionKey: SessionKey, dir: URL) throws -> OwnedSessionLock {
        try StorageIO.createPrivateDirectory(dir)
        let canonical = OwnershipLock.canonicalPath(sessionFile)
        let url = OwnershipLock.lockURL(canonicalPath: canonical, in: dir)
        let fd = try StorageIO.open(url, O_RDWR | O_CREAT)
        do {
            try lock(fd, url: url, sessionFile: canonical)
            let body = try JSONEncoder().encode(Body(sessionFile: canonical, sessionId: sessionId, sessionKey: sessionKey))
            try StorageIO.truncate(fd, to: 0, url)
            try StorageIO.write(fd, body, url)
        } catch {
            StorageIO.close(fd)
            throw error
        }
        return OwnedSessionLock(sessionFile: canonical, lockURL: url, fd: fd)
    }

    /// Drops the lock. Idempotent. The lock file stays: unlinking it would race a concurrent acquirer, and
    /// `AppSupportPaths.prepare()` recreates `run/` on every daemon start.
    public func release() {
        let fd = descriptor.withLock { fd in
            defer { fd = -1 }
            return fd
        }
        guard fd >= 0 else { return }
        _ = flock(fd, LOCK_UN)
        StorageIO.close(fd)
    }

    private static func lock(_ fd: Int32, url: URL, sessionFile: String) throws {
        var attempt = 1
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            if code == EINTR { continue }
            guard code == EWOULDBLOCK else {
                throw BridgeError.system(operation: "flock", path: StorageIO.displayPath(url), code: code)
            }
            guard attempt < contentionAttempts else { throw BridgeError.alreadyOwned(sessionFile: sessionFile) }
            attempt += 1
            usleep(contentionBackoffMicroseconds)
        }
    }
}
