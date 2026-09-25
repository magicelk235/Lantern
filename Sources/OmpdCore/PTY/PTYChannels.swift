import Darwin
import Dispatch
import IDEProtocol
import os

/// The daemon side of one PTY: the non-blocking master fd, its read source, and a FIFO of input the tty could
/// not take yet (drained by a write source, so a large paste never blocks and is never dropped).
/// Confined to the main queue (`PTYPool`'s executor); handlers re-enter the pool.
final class MasterChannel {
    /// Upper bound for input queued while the program is not reading its tty.
    static let maxPendingInput = 16 << 20

    let fd: Int32
    private let readSource: any DispatchSourceRead
    private let onWritable: @Sendable () -> Void
    private var writeSource: (any DispatchSourceWrite)?
    private var pending: [UInt8] = []
    private var pendingStart = 0
    private var isClosed = false

    init(fd: Int32, onReadable: @escaping @Sendable () -> Void, onWritable: @escaping @Sendable () -> Void) {
        self.fd = fd
        self.onWritable = onWritable
        readSource = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        readSource.setEventHandler(handler: onReadable)
        readSource.setCancelHandler { Darwin.close(fd) }
        readSource.resume()
    }

    deinit { close() }

    /// Writes as much as the tty accepts now and queues the rest.
    func write(_ bytes: UnsafeRawBufferPointer) throws {
        guard !isClosed, !bytes.isEmpty else { return }
        var offset = 0
        if pending.count == pendingStart {
            while offset < bytes.count {
                let n = Darwin.write(fd, bytes.baseAddress! + offset, bytes.count - offset)
                if n > 0 { offset += n; continue }
                if n < 0 && errno == EINTR { continue }
                if n < 0 && errno == EAGAIN { break }
                return // EIO: nothing reads the tty any more; input is moot.
            }
            if offset == bytes.count { return }
        }
        guard pending.count - pendingStart + bytes.count - offset <= Self.maxPendingInput else {
            throw DaemonError(.internal, "PTY input buffer full: the program is not reading its terminal")
        }
        if pendingStart > 0 && pendingStart >= pending.count / 2 {
            pending.removeFirst(pendingStart)
            pendingStart = 0
        }
        pending.append(contentsOf: bytes[offset...])
        armWriteSource()
    }

    /// Called when the master is writable again.
    func flushPending() {
        guard !isClosed else { return }
        while pendingStart < pending.count {
            let n = pending.withUnsafeBytes { raw in
                Darwin.write(fd, raw.baseAddress! + pendingStart, raw.count - pendingStart)
            }
            if n > 0 { pendingStart += n; continue }
            if n < 0 && errno == EINTR { continue }
            if n < 0 && errno == EAGAIN { return }
            break // EIO: drop what is left.
        }
        pending.removeAll()
        pendingStart = 0
        writeSource?.cancel()
        writeSource = nil
    }

    /// Stops reading and closes the master (the tty hangs up once no process holds it either).
    func close() {
        guard !isClosed else { return }
        isClosed = true
        pending.removeAll()
        pendingStart = 0
        writeSource?.cancel()
        writeSource = nil
        readSource.cancel() // its cancel handler closes `fd`
    }

    private func armWriteSource() {
        guard writeSource == nil else { return }
        // The write source watches its own descriptor so each source can close its fd in its cancel handler.
        let watched = fcntl(fd, F_DUPFD_CLOEXEC, 0)
        guard watched >= 0 else { return }
        let source = DispatchSource.makeWriteSource(fileDescriptor: watched, queue: .main)
        source.setEventHandler(handler: onWritable)
        source.setCancelHandler { Darwin.close(watched) }
        writeSource = source
        source.resume()
    }
}

/// Reaps one child with a dispatch process source (no zombies), independent of the pool's lifetime: the source
/// keeps itself alive until the child is reaped. Signals are only sent while the child is unreaped, so a
/// recycled pid is never hit.
final class ChildReaper: Sendable {
    let pid: pid_t
    private let reaped = OSAllocatedUnfairLock(initialState: false)

    /// `onExit` runs on the main queue with the `waitpid` status (0 if someone else reaped the child).
    init(pid: pid_t, onExit: @escaping @Sendable (Int32) -> Void) {
        self.pid = pid
        let reaped = reaped
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        let reap = {
            let status: Int32? = reaped.withLock { done in
                guard !done else { return nil }
                var status: Int32 = 0
                let result = waitpid(pid, &status, WNOHANG)
                guard result == pid || (result < 0 && errno == ECHILD) else { return nil }
                done = true
                return result == pid ? status : 0
            }
            guard let status else { return }
            source.cancel()
            onExit(status)
        }
        source.setEventHandler(handler: reap)
        // An exit that happened before the kqueue registration produces no event: check once registered.
        source.setRegistrationHandler(handler: reap)
        source.resume()
    }

    var isReaped: Bool { reaped.withLock { $0 } }

    /// Sends `signal` to the child's process group (it is a session leader) unless it has been reaped.
    func signalGroup(_ signal: Int32) {
        let pid = pid
        reaped.withLock { done in
            if !done { _ = kill(-pid, signal) }
        }
    }
}
