import Darwin
import Dispatch
import Foundation
import os

let bridgeLog = Logger(subsystem: "com.magicelklabs.lantern.ompd", category: "bridge")

/// POSIX unix-domain-socket plumbing for `BridgeServer`. Network.framework cannot report the peer's pid, and the
/// bridge authenticates omp by `LOCAL_PEERPID`.
enum BridgeSocket {
    /// `sun_path` capacity, including the terminating NUL.
    static let pathCapacity = MemoryLayout.size(ofValue: sockaddr_un().sun_path)

    static func address(_ path: String) throws -> sockaddr_un {
        guard path.utf8.count < pathCapacity else { throw BridgeError.socketPathTooLong(path: path) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path.utf8) }
        return address
    }

    /// A non-blocking, close-on-exec listening socket bound to `path` with mode 0600.
    static func listen(path: String) throws -> Int32 {
        var address = try address(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw BridgeError.system(operation: "socket", path: path, code: errno) }
        var bound = false
        do {
            try check(fcntl(fd, F_SETFD, FD_CLOEXEC), "fcntl(FD_CLOEXEC)", path)
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard result == 0 else {
                let code = errno
                throw code == EADDRINUSE ? BridgeError.addressInUse(path: path) : BridgeError.system(operation: "bind", path: path, code: code)
            }
            bound = true
            try check(chmod(path, 0o600), "chmod", path)
            try check(Darwin.listen(fd, 64), "listen", path)
            let flags = fcntl(fd, F_GETFL)
            try check(flags, "fcntl(F_GETFL)", path)
            try check(fcntl(fd, F_SETFL, flags | O_NONBLOCK), "fcntl(O_NONBLOCK)", path)
            return fd
        } catch {
            Darwin.close(fd)
            if bound { unlink(path) }
            throw error
        }
    }

    /// Removes a socket file left behind by a dead listener. Never deletes a non-socket or a socket someone listens on.
    static func removeStale(_ path: String) throws {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            if errno == ENOENT { return }
            throw BridgeError.system(operation: "lstat", path: path, code: errno)
        }
        guard info.st_mode & S_IFMT == S_IFSOCK else { throw BridgeError.socketPathOccupied(path: path) }
        guard try !isListening(path) else { throw BridgeError.addressInUse(path: path) }
        guard unlink(path) == 0 || errno == ENOENT else { throw BridgeError.system(operation: "unlink", path: path, code: errno) }
    }

    /// Probes `path` with a non-blocking connect; only "refused" or "gone" count as nobody listening.
    static func isListening(_ path: String) throws -> Bool {
        var address = try address(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw BridgeError.system(operation: "socket", path: path, code: errno) }
        defer { Darwin.close(fd) }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if result == 0 { return true }
        let code = errno
        return code != ECONNREFUSED && code != ENOENT
    }

    /// Pid of the process that connected `fd`, recorded by the kernel at connect time.
    static func peerPID(_ fd: Int32) -> pid_t? {
        var pid: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0 else { return nil }
        return pid
    }

    private static func check(_ result: Int32, _ operation: String, _ path: String) throws {
        guard result >= 0 else { throw BridgeError.system(operation: operation, path: path, code: errno) }
    }
}

/// Device + inode of the socket file a server bound, so `stop()` never unlinks a successor's socket.
struct SocketFileIdentity: Sendable, Equatable {
    let device: dev_t
    let inode: ino_t

    init?(path: String) {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        device = info.st_dev
        inode = info.st_ino
    }
}

/// Accept loop over a listening socket. Accepted sockets are close-on-exec (omp children never inherit them) and
/// never raise SIGPIPE.
final class BridgeListener: Sendable {
    private let source: any DispatchSourceRead

    init(fd: Int32, onAccept: @escaping @Sendable (_ client: Int32, _ peerPID: pid_t?) -> Void) {
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: DispatchQueue(label: "com.magicelklabs.lantern.bridge.listener"))
        source.setEventHandler {
            while true {
                let client = accept(fd, nil, nil)
                guard client >= 0 else {
                    let code = errno
                    if code == EINTR || code == ECONNABORTED { continue }
                    if code != EAGAIN && code != EWOULDBLOCK {
                        bridgeLog.error("bridge accept failed: \(String(cString: strerror(code)), privacy: .public)")
                    }
                    return
                }
                _ = fcntl(client, F_SETFD, FD_CLOEXEC)
                var on: Int32 = 1
                _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
                onAccept(client, BridgeSocket.peerPID(client))
            }
        }
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
    }

    /// Stops accepting and closes the listening socket.
    func cancel() {
        source.cancel()
    }
}

/// One JSON-lines connection over a DispatchIO stream channel. Complete lines (without the newline) are delivered in
/// order on `lines`, which finishes when either side closes the connection.
final class BridgeConnection: Sendable {
    let id: Int
    /// `LOCAL_PEERPID` at accept time; nil if the kernel would not say.
    let peerPID: pid_t?
    let lines: AsyncStream<Data>

    private let fd: Int32
    private let sink: AsyncStream<Data>.Continuation
    private let io: DispatchIO
    private let queue: DispatchQueue
    private let maxLineBytes: Int
    private let state = OSAllocatedUnfairLock(initialState: State())

    private struct State: Sendable {
        var buffer: [UInt8] = []
        /// Bytes of `buffer` already searched for a newline.
        var scanned = 0
        var closed = false
        /// `finishWriting`: nothing is sent any more.
        var writingFinished = false
    }

    init(fd: Int32, id: Int, peerPID: pid_t?, maxLineBytes: Int) {
        self.fd = fd
        self.id = id
        self.peerPID = peerPID
        self.maxLineBytes = maxLineBytes
        (lines, sink) = AsyncStream.makeStream(of: Data.self)
        let queue = DispatchQueue(label: "com.magicelklabs.lantern.bridge.connection")
        self.queue = queue
        io = DispatchIO(type: .stream, fileDescriptor: fd, queue: queue, cleanupHandler: { _ in Darwin.close(fd) })
        io.setLimit(lowWater: 1)
    }

    func start() {
        io.read(offset: 0, length: Int.max, queue: queue) { [self] done, data, _ in
            if let data, !data.isEmpty { received(data) }
            if done { close() } // end of file, error, or our own close
        }
    }

    /// Queues `bytes`; with `thenClose`, closes the connection once they are written (or failed). Dropped after
    /// `finishWriting`.
    func send(_ bytes: Data, thenClose: Bool = false) {
        guard !state.withLock({ $0.closed || $0.writingFinished }) else { return }
        let data = bytes.withUnsafeBytes { DispatchData(bytes: $0) }
        io.write(offset: 0, data: data, queue: queue) { [self] done, _, error in
            if done && (error != 0 || thenClose) { close() }
        }
    }

    /// Ends ompd's side (`shutdown(SHUT_WR)`): the peer reads the end of its input. Reading goes on until the peer
    /// closes; later `send`s are dropped. (Not behind a DispatchIO barrier: that would wait for the read in flight.)
    func finishWriting() {
        let first = state.withLock { s in
            defer { s.writingFinished = true }
            return !s.writingFinished && !s.closed
        }
        guard first else { return }
        _ = shutdown(fd, SHUT_WR)
    }

    /// Idempotent. Pending reads and writes are abandoned; `lines` finishes after the lines already delivered.
    func close() {
        let first = state.withLock { s in
            defer { s.closed = true }
            return !s.closed
        }
        guard first else { return }
        io.close(flags: .stop)
        sink.finish()
    }

    private func received(_ chunk: DispatchData) {
        let maxLineBytes = maxLineBytes
        let (complete, overflow) = state.withLock { s -> ([Data], Bool) in
            guard !s.closed else { return ([], false) }
            s.buffer.append(contentsOf: chunk)
            var complete: [Data] = []
            var lineStart = 0
            var index = s.scanned
            while let newline = s.buffer[index...].firstIndex(of: 0x0A) {
                if newline > lineStart { complete.append(Data(s.buffer[lineStart..<newline])) }
                lineStart = newline + 1
                index = lineStart
            }
            s.buffer.removeFirst(lineStart)
            s.scanned = s.buffer.count
            return (complete, s.buffer.count > maxLineBytes)
        }
        for line in complete { sink.yield(line) }
        if overflow {
            bridgeLog.error("bridge connection \(self.id) sent a line over \(self.maxLineBytes) bytes; closing")
            close()
        }
    }
}
