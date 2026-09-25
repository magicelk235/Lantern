import CryptoKit
import Darwin
import Foundation
import Testing
@testable import OmpdCore

/// Runs `/usr/bin/python3 -c script args...` and returns its exit status.
private func python(_ script: String, _ arguments: [String]) async throws -> Int32 {
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/python3")
    process.arguments = ["-c", script] + arguments
    try process.run()
    return await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            process.waitUntilExit()
            continuation.resume(returning: process.terminationStatus)
        }
    }
}

/// The ide-bridge's probe: a shared non-blocking open-lock. Exit 0 = free, 11 = held (EAGAIN).
private let bridgeProbe = """
    import os, sys
    try:
        os.close(os.open(sys.argv[1], os.O_RDONLY | os.O_SHLOCK | os.O_NONBLOCK))
    except BlockingIOError:
        sys.exit(11)
    """

@Suite struct BridgeOwnershipLockTests {
    @Test func secondAcquirerIsExcludedUntilRelease() throws {
        let dir = try StorageTempDir()
        let session = dir.url.appending(path: "2026-09-25_0199aaaa.jsonl").path(percentEncoded: false)
        try Data("{}\n".utf8).write(to: URL(filePath: session))
        let owned = dir.url.appending(path: "owned", directoryHint: .isDirectory)

        let lock = try OwnedSessionLock.acquire(sessionFile: session, sessionId: "0199aaaa", sessionKey: "k1", dir: owned)
        #expect(throws: BridgeError.alreadyOwned(sessionFile: lock.sessionFile)) {
            try OwnedSessionLock.acquire(sessionFile: session, sessionId: "0199aaaa", sessionKey: "k2", dir: owned)
        }
        let body = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: lock.lockURL))
        #expect(body == ["sessionFile": lock.sessionFile, "sessionId": "0199aaaa", "sessionKey": "k1"])

        lock.release()
        lock.release()
        let next = try OwnedSessionLock.acquire(sessionFile: session, sessionId: "0199aaaa", sessionKey: "k2", dir: owned)
        #expect(next.lockURL == lock.lockURL)
    }

    @Test func lockNameIsTheHashOfTheCanonicalPath() throws {
        let dir = try StorageTempDir()
        let owned = dir.url.appending(path: "owned", directoryHint: .isDirectory)
        let real = dir.url.appending(path: "Sessions", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let link = dir.url.appending(path: "link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let file = real.appending(path: "s.jsonl").path(percentEncoded: false)
        let viaLink = link.appending(path: "s.jsonl").path(percentEncoded: false)

        // Not on disk yet: resolved through the directory, so the name does not change once omp creates the file.
        let before = OwnershipLock.lockURL(for: viaLink, in: owned)
        try Data().write(to: URL(filePath: file))
        let after = OwnershipLock.lockURL(for: viaLink, in: owned)
        #expect(before == after)
        if FileManager.default.fileExists(atPath: file.uppercased()) { // case-insensitive volume (the APFS default)
            #expect(OwnershipLock.lockURL(for: file.uppercased(), in: owned) == after)
        }

        var resolved = [CChar](repeating: 0, count: Int(PATH_MAX))
        let canonical = String(cString: try #require(realpath(file, &resolved)))
        let hex = SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
        #expect(after.lastPathComponent == "\(hex).lock")
    }

    @Test func otherProcessesSeeTheLockUntilRelease() async throws {
        let dir = try StorageTempDir()
        let session = dir.url.appending(path: "s.jsonl").path(percentEncoded: false)
        let lock = try OwnedSessionLock.acquire(sessionFile: session, sessionId: nil, sessionKey: "k1", dir: dir.url)
        let lockPath = lock.lockURL.path(percentEncoded: false)
        #expect(try await python(bridgeProbe, [lockPath]) == 11)
        lock.release()
        #expect(try await python(bridgeProbe, [lockPath]) == 0)
    }

    @Test func lockHeldByAProcessIsFreedWhenItDies() async throws {
        let dir = try StorageTempDir()
        let session = dir.url.appending(path: "s.jsonl").path(percentEncoded: false)
        let lockURL = OwnershipLock.lockURL(for: session, in: dir.url)
        let ready = dir.url.appending(path: "ready")
        let holder = Process()
        holder.executableURL = URL(filePath: "/usr/bin/python3")
        holder.arguments = [
            "-c",
            "import fcntl, os, sys, time\nfd = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT, 0o600)\n"
                + "fcntl.flock(fd, fcntl.LOCK_EX)\nopen(sys.argv[2], 'w').close()\ntime.sleep(60)",
            lockURL.path(percentEncoded: false), ready.path(percentEncoded: false),
        ]
        try holder.run()
        defer { if holder.isRunning { kill(holder.processIdentifier, SIGKILL) } }
        try await bridgeWithin("the lock holder to start") {
            while !FileManager.default.fileExists(atPath: ready.path(percentEncoded: false)) { try await Task.sleep(for: .milliseconds(20)) }
        }

        #expect(throws: BridgeError.alreadyOwned(sessionFile: OwnershipLock.canonicalPath(session))) {
            try OwnedSessionLock.acquire(sessionFile: session, sessionId: nil, sessionKey: "k1", dir: dir.url)
        }
        kill(holder.processIdentifier, SIGKILL)
        holder.waitUntilExit()
        _ = try OwnedSessionLock.acquire(sessionFile: session, sessionId: nil, sessionKey: "k1", dir: dir.url)
    }

    /// ompd spawns omp (and PTY shells) while holding locks; a child that inherited the descriptor would keep the
    /// session locked after ompd dies. Spawned with plain posix_spawn, which inherits every descriptor without FD_CLOEXEC.
    @Test func spawnedChildrenDoNotInheritTheLock() async throws {
        let dir = try StorageTempDir()
        let lock = try OwnedSessionLock.acquire(
            sessionFile: dir.url.appending(path: "s.jsonl").path(percentEncoded: false), sessionId: nil, sessionKey: "k1", dir: dir.url)
        let script = """
            import os, sys
            target = os.stat(sys.argv[1])
            for fd in range(3, 1024):
                try:
                    st = os.fstat(fd)
                except OSError:
                    continue
                if (st.st_dev, st.st_ino) == (target.st_dev, target.st_ino):
                    sys.exit(3)
            """
        let arguments = ["/usr/bin/python3", "-c", script, lock.lockURL.path(percentEncoded: false)]
        let environment = ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" }
        let argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup($0) } + [nil]
        defer { for pointer in argv + envp { free(pointer) } }
        var pid: pid_t = 0
        #expect(posix_spawn(&pid, "/usr/bin/python3", nil, nil, argv, envp) == 0)
        let status = try await bridgeWithin("the fd scanner") { [pid] in
            await withCheckedContinuation { continuation in
                DispatchQueue.global().async {
                    var status: Int32 = 0
                    waitpid(pid, &status, 0)
                    continuation.resume(returning: status)
                }
            }
        }
        #expect(status == 0, "child inherited the ownership lock descriptor (wait status \(status))")
        lock.release()
    }
}
