import Darwin
import Foundation
import IDEProtocol

/// One ompd per `$APP_SUPPORT`: an exclusive `flock` on `<root>/ompd.lock`, held for the daemon's lifetime and
/// dropped by the kernel when it dies. It lives outside `run/` because `prepare()` wipes `run/`, which must never
/// happen under a daemon that is still running.
public final class DaemonInstanceLock: Sendable {
    private let fd: Int32

    public enum Failure: Error, CustomStringConvertible {
        /// Another ompd holds the lock; `owner` is the pid it recorded, if readable.
        case alreadyRunning(lockFile: String, owner: String?)
        case system(operation: String, path: String, code: Int32)

        public var description: String {
            switch self {
            case .alreadyRunning(let lockFile, let owner):
                "another ompd is running (\(lockFile)\(owner.map { ", pid \($0)" } ?? ""))"
            case .system(let operation, let path, let code):
                "\(operation) \(path): \(String(cString: strerror(code)))"
            }
        }
    }

    public static func lockFile(in paths: AppSupportPaths) -> URL {
        paths.root.appending(path: "ompd.lock", directoryHint: .notDirectory)
    }

    /// Takes the lock (creating `root` with mode 0700 if needed) and records this process's pid in it.
    public static func acquire(_ paths: AppSupportPaths) throws -> DaemonInstanceLock {
        let url = lockFile(in: paths)
        let path = url.path(percentEncoded: false)
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure.system(operation: "open", path: path, code: errno) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            let owner = try? String(contentsOfFile: path, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            close(fd)
            if code == EWOULDBLOCK { throw Failure.alreadyRunning(lockFile: path, owner: owner?.isEmpty == false ? owner : nil) }
            throw Failure.system(operation: "flock", path: path, code: code)
        }
        let pid = Array("\(getpid())\n".utf8)
        _ = ftruncate(fd, 0)
        _ = pid.withUnsafeBytes { pwrite(fd, $0.baseAddress, $0.count, 0) }
        return DaemonInstanceLock(fd: fd)
    }

    private init(fd: Int32) {
        self.fd = fd
    }

    /// The lock the previous image of this process held on `descriptor` and kept open across an in-place upgrade: held
    /// still (`flock` locks belong to the open file), close-on-exec again. Nil when `descriptor` is not `paths`' lock file.
    init?(adopting descriptor: Int32, in paths: AppSupportPaths) {
        var inherited = stat()
        var named = stat()
        guard descriptor >= 0, fstat(descriptor, &inherited) == 0,
              stat(Self.lockFile(in: paths).path(percentEncoded: false), &named) == 0,
              inherited.st_dev == named.st_dev, inherited.st_ino == named.st_ino
        else { return nil }
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        fd = descriptor
    }

    /// The descriptor holding the lock, kept open for the next image of an in-place upgrade.
    var descriptor: Int32 { fd }

    deinit {
        close(fd)
    }
}
