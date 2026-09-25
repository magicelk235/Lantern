import Foundation
import os

/// Pipes, dispatch sources and request bookkeeping for one omp child.
///
/// Every stdout/stderr read, frame decode, write completion and the exit hand-off run on one serial
/// queue that reads the pipes whenever data is available. Draining never depends on how fast
/// `OmpProcess.output` is consumed: frames wait in the unbounded stream, never in omp's spill file.
final class OmpChildIO: Sendable {
    private let queue = DispatchQueue(label: "omp-rpc.child", qos: .userInitiated)
    private let output: AsyncStream<OmpOutput>.Continuation
    /// Read-side state. Locked on `queue` only (after setup), so it is uncontended; the lock makes the
    /// queue confinement checkable.
    private let reader = OSAllocatedUnfairLock(initialState: Reader())
    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Unread stderr is published at the latest when this many bytes lack a newline.
    private static let maxStderrLineBytes = 64 << 10

    private struct ReadEnd: Sendable {
        let fd: Int32
        let source: any DispatchSourceRead
    }

    private struct Reader: Sendable {
        var decoder = RPCFrameDecoder()
        var buffer = [UInt8](repeating: 0, count: 64 << 10)
        var stdout: ReadEnd?
        var stderr: ReadEnd?
        var stderrText: [UInt8] = []
        /// Set after a protocol violation: stdout is still drained (so omp never blocks) but ignored.
        var discardStdout = false
        var finalized = false
    }

    private struct State: Sendable {
        var launched = false
        var pid: pid_t?
        /// The child was reaped; its pid may be reused and must not be signalled.
        var reaped = false
        var stdin: DispatchIO?
        var stdinOpen = false
        var pending: [String: CheckedContinuation<JSONValue, any Error>] = [:]
        var readyFrame: JSONValue?
        var readyWaiter: CheckedContinuation<JSONValue, any Error>?
        var readyFailure: (any Error)?
        var violation: OmpRPCError?
        var exit: OmpExit?
        var exitWaiters: [CheckedContinuation<OmpExit, Never>] = []

        /// Why nothing can be written right now, if anything.
        var writeBlocker: OmpRPCError? {
            if let violation { return violation }
            if let exit { return .exited(exit) }
            if !stdinOpen { return .stdinClosed }
            return nil
        }
    }

    init(output: AsyncStream<OmpOutput>.Continuation) {
        self.output = output
    }

    var pid: pid_t? { state.withLock { $0.pid } }

    var protocolViolation: OmpRPCError? { state.withLock { $0.violation } }

    // MARK: Launch

    /// Wires `process` to fresh pipes and spawns it.
    func launch(_ process: Process) throws {
        let pipes = try Self.makePipes(count: 3)
        let stdin = pipes[0], stdout = pipes[1], stderr = pipes[2]
        _ = fcntl(stdin.write, F_SETNOSIGPIPE, 1)
        Self.setNonBlocking(stdout.read)
        Self.setNonBlocking(stderr.read)
        process.standardInput = FileHandle(fileDescriptor: stdin.read, closeOnDealloc: false)
        process.standardOutput = FileHandle(fileDescriptor: stdout.write, closeOnDealloc: false)
        process.standardError = FileHandle(fileDescriptor: stderr.write, closeOnDealloc: false)
        process.terminationHandler = { [self] process in processDidTerminate(OmpExit(process)) }

        let channel = DispatchIO(type: .stream, fileDescriptor: stdin.write, queue: queue) { _ in close(stdin.write) }
        // Reading starts before the spawn, so nothing the child writes can slip past.
        startReading(stdout: stdout.read, stderr: stderr.read)
        state.withLock {
            $0.stdin = channel
            $0.stdinOpen = true
            $0.launched = true
        }
        do {
            try process.run()
        } catch {
            process.terminationHandler = nil
            close(stdin.read)
            close(stdout.write)
            close(stderr.write)
            state.withLock { $0.stdinOpen = false }
            channel.close(flags: .stop)
            queue.async { [self] in finalize(OmpExit(code: nil, signal: nil)) }
            throw OmpRPCError.launchFailed(error.localizedDescription)
        }
        // The child holds its own copies now; closing ours lets EOF propagate both ways.
        close(stdin.read)
        close(stdout.write)
        close(stderr.write)
        let pid = process.processIdentifier
        state.withLock { s in
            s.pid = pid
            // stdout may have broken the protocol before the pid was known.
            if s.violation != nil, !s.reaped { kill(pid, SIGTERM) }
        }
    }

    /// Called when the owning `OmpProcess` goes away: a running child gets EOF on stdin (omp then
    /// disposes its session and exits); a never-started one just ends `output`.
    func abandon() {
        if state.withLock({ $0.launched }) {
            closeStdin()
        } else {
            output.yield(.exited(OmpExit(code: nil, signal: nil)))
            output.finish()
        }
    }

    // MARK: Writing

    /// Writes `line` and waits for the `response` whose `id` matches.
    func request(id: String, line: Data) async throws -> JSONValue {
        let data = line.withUnsafeBytes { DispatchData(bytes: $0) }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<JSONValue, any Error>) in
                let blocker = state.withLock { s -> OmpRPCError? in
                    if let blocker = s.writeBlocker { return blocker }
                    s.pending[id] = continuation
                    s.stdin?.write(offset: 0, data: data, queue: queue) { [self] done, _, error in
                        if done, error != 0 { failRequest(id, with: OmpRPCError.writeFailed(errno: error)) }
                    }
                    return nil
                }
                if let blocker {
                    continuation.resume(throwing: blocker)
                } else if Task.isCancelled {
                    failRequest(id, with: CancellationError())
                }
            }
        } onCancel: {
            failRequest(id, with: CancellationError())
        }
    }

    /// Writes `line` without expecting a response.
    func post(_ line: Data) throws {
        let data = line.withUnsafeBytes { DispatchData(bytes: $0) }
        try state.withLock { s in
            if let blocker = s.writeBlocker { throw blocker }
            s.stdin?.write(offset: 0, data: data, queue: queue) { _, _, _ in }
        }
    }

    /// Closes stdin once queued writes have drained.
    func closeStdin() {
        state.withLock { s -> DispatchIO? in
            guard s.stdinOpen else { return nil }
            s.stdinOpen = false
            return s.stdin
        }?.close()
    }

    func signal(_ signal: Int32) {
        state.withLock { s in
            if !s.reaped, let pid = s.pid { kill(pid, signal) }
        }
    }

    private func failRequest(_ id: String, with error: any Error) {
        state.withLock { $0.pending.removeValue(forKey: id) }?.resume(throwing: error)
    }

    // MARK: Waiting

    func awaitReady() async throws -> JSONValue {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<JSONValue, any Error>) in
                let early = state.withLock { s -> Result<JSONValue, any Error>? in
                    if let frame = s.readyFrame { return .success(frame) }
                    if let failure = s.readyFailure { return .failure(failure) }
                    if let violation = s.violation { return .failure(violation) }
                    if let exit = s.exit { return .failure(OmpRPCError.exited(exit)) }
                    s.readyWaiter = continuation
                    return nil
                }
                if let early {
                    continuation.resume(with: early)
                } else if Task.isCancelled {
                    failReady(CancellationError())
                }
            }
        } onCancel: {
            failReady(CancellationError())
        }
    }

    /// Fails `awaitReady` (now or when it is called) unless `ready` already arrived.
    func failReady(_ error: any Error) {
        state.withLock { s -> CheckedContinuation<JSONValue, any Error>? in
            guard s.readyFrame == nil else { return nil }
            if s.readyFailure == nil { s.readyFailure = error }
            defer { s.readyWaiter = nil }
            return s.readyWaiter
        }?.resume(throwing: error)
    }

    func waitForExit() async -> OmpExit {
        await withCheckedContinuation { continuation in
            let exit = state.withLock { s -> OmpExit? in
                if let exit = s.exit { return exit }
                s.exitWaiters.append(continuation)
                return nil
            }
            if let exit { continuation.resume(returning: exit) }
        }
    }

    // MARK: Reading (on `queue`)

    private func startReading(stdout: Int32, stderr: Int32) {
        let stdoutSource = DispatchSource.makeReadSource(fileDescriptor: stdout, queue: queue)
        stdoutSource.setEventHandler { [self] in pumpStdout(maxReads: 16) }
        stdoutSource.setCancelHandler { close(stdout) }
        let stderrSource = DispatchSource.makeReadSource(fileDescriptor: stderr, queue: queue)
        stderrSource.setEventHandler { [self] in pumpStderr(maxReads: 16) }
        stderrSource.setCancelHandler { close(stderr) }
        reader.withLock {
            $0.stdout = ReadEnd(fd: stdout, source: stdoutSource)
            $0.stderr = ReadEnd(fd: stderr, source: stderrSource)
        }
        stdoutSource.activate()
        stderrSource.activate()
    }

    /// Reads stdout until it would block, reaches EOF, or `maxReads` reads were made, publishing
    /// every frame as soon as it is decoded.
    private func pumpStdout(maxReads: Int) {
        reader.withLock { r in
            guard let end = r.stdout else { return }
            var buffer: [UInt8] = []
            swap(&buffer, &r.buffer)
            defer { swap(&buffer, &r.buffer) }
            for _ in 0..<maxReads {
                let (count, error) = buffer.withUnsafeMutableBytes { bytes in
                    let count = read(end.fd, bytes.baseAddress, bytes.count)
                    return (count, errno)
                }
                if count > 0 {
                    guard !r.discardStdout else { continue }
                    do {
                        try buffer.withUnsafeBytes { bytes in
                            try r.decoder.push(UnsafeRawBufferPointer(rebasing: bytes[..<count])) { publish($0) }
                        }
                    } catch {
                        r.discardStdout = true
                        protocolViolated(error)
                    }
                    continue
                }
                if count < 0, error == EINTR { continue }
                if count < 0, error == EAGAIN { return }
                // EOF (or an unreadable pipe): stdout is over.
                finishStdout(&r)
                return
            }
        }
    }

    private func finishStdout(_ r: inout Reader) {
        guard let end = r.stdout else { return }
        if !r.discardStdout {
            do {
                try r.decoder.finish { publish($0) }
            } catch {
                r.discardStdout = true
                protocolViolated(error)
            }
        }
        end.source.cancel()
        r.stdout = nil
    }

    private func pumpStderr(maxReads: Int) {
        reader.withLock { r in
            guard let end = r.stderr else { return }
            var buffer: [UInt8] = []
            swap(&buffer, &r.buffer)
            defer { swap(&buffer, &r.buffer) }
            for _ in 0..<maxReads {
                let (count, error) = buffer.withUnsafeMutableBytes { bytes in
                    let count = read(end.fd, bytes.baseAddress, bytes.count)
                    return (count, errno)
                }
                if count > 0 {
                    r.stderrText.append(contentsOf: buffer[..<count])
                    publishStderr(&r.stderrText, flush: false)
                    continue
                }
                if count < 0, error == EINTR { continue }
                if count < 0, error == EAGAIN { return }
                finishStderr(&r)
                return
            }
        }
    }

    private func finishStderr(_ r: inout Reader) {
        guard let end = r.stderr else { return }
        publishStderr(&r.stderrText, flush: true)
        end.source.cancel()
        r.stderr = nil
    }

    /// Publishes complete lines from `text` (everything when `flush`), keeping the unterminated tail.
    private func publishStderr(_ text: inout [UInt8], flush: Bool) {
        var cut = 0
        if flush {
            cut = text.count
        } else if let newline = text.lastIndex(of: 0x0A) {
            cut = newline + 1
        } else if text.count >= Self.maxStderrLineBytes {
            cut = Self.maxStderrLineBytes
            // Back up to the lead byte of a UTF-8 sequence that straddles the cut.
            var lead = cut
            while lead < text.count, lead > cut - 4, text[lead] & 0xC0 == 0x80 { lead -= 1 }
            if lead < cut, text[lead] & 0xC0 == 0xC0 { cut = lead }
        }
        guard cut > 0 else { return }
        output.yield(.stderr(String(decoding: text[..<cut], as: UTF8.self)))
        text.removeFirst(cut)
    }

    private func publish(_ frame: JSONValue) {
        output.yield(.frame(frame))
        guard case .object(let fields) = frame, case .string(let type)? = fields["type"] else { return }
        if type == OmpEventType.response.rawValue, case .string(let id)? = fields["id"] {
            state.withLock { $0.pending.removeValue(forKey: id) }?.resume(returning: frame)
        } else if type == OmpEventType.ready.rawValue {
            state.withLock { s -> CheckedContinuation<JSONValue, any Error>? in
                guard s.readyFrame == nil, s.readyFailure == nil else { return nil }
                s.readyFrame = frame
                defer { s.readyWaiter = nil }
                return s.readyWaiter
            }?.resume(returning: frame)
        }
    }

    /// stdout can no longer be trusted: fail everything waiting on it and ask omp to shut down.
    private func protocolViolated(_ error: any Error) {
        let violation = error as? OmpRPCError ?? .protocolViolation(String(describing: error))
        let (requests, ready) = state.withLock { s -> ([CheckedContinuation<JSONValue, any Error>], CheckedContinuation<JSONValue, any Error>?) in
            s.violation = violation
            let requests = Array(s.pending.values)
            s.pending.removeAll()
            let ready = s.readyWaiter
            s.readyWaiter = nil
            if !s.reaped, let pid = s.pid { kill(pid, SIGTERM) }
            return (requests, ready)
        }
        for request in requests { request.resume(throwing: violation) }
        ready?.resume(throwing: violation)
    }

    // MARK: Exit (on `queue`)

    private func processDidTerminate(_ exit: OmpExit) {
        state.withLock { $0.reaped = true }
        queue.async { [self] in finalize(exit) }
    }

    private func finalize(_ exit: OmpExit) {
        let first = reader.withLock { r in
            defer { r.finalized = true }
            return !r.finalized
        }
        guard first else { return }
        // Everything omp wrote before it exited is already buffered in the pipes: drain it. A pipe
        // still open afterwards is held by a descendant that inherited it, so stop listening.
        pumpStdout(maxReads: 64)
        pumpStderr(maxReads: 64)
        reader.withLock { r in
            finishStdout(&r)
            finishStderr(&r)
        }
        let (stdin, requests, ready, waiters) = state.withLock { s in
            s.exit = exit
            s.stdinOpen = false
            let stdin = s.stdin
            s.stdin = nil
            let requests = Array(s.pending.values)
            s.pending.removeAll()
            let ready = s.readyWaiter
            s.readyWaiter = nil
            let waiters = s.exitWaiters
            s.exitWaiters.removeAll()
            return (stdin, requests, ready, waiters)
        }
        stdin?.close(flags: .stop)
        output.yield(.exited(exit))
        output.finish()
        let error = OmpRPCError.exited(exit)
        for request in requests { request.resume(throwing: error) }
        ready?.resume(throwing: error)
        for waiter in waiters { waiter.resume(returning: exit) }
    }

    // MARK: File descriptors

    private static func makePipes(count: Int) throws -> [(read: Int32, write: Int32)] {
        var pipes: [(read: Int32, write: Int32)] = []
        for _ in 0..<count {
            var fds: [Int32] = [-1, -1]
            guard pipe(&fds) == 0 else {
                let code = errno
                for pipe in pipes {
                    close(pipe.read)
                    close(pipe.write)
                }
                throw OmpRPCError.launchFailed("pipe() failed: \(String(cString: strerror(code)))")
            }
            // Keep these out of any other child the host spawns (PTY shells, other omp processes):
            // a stray copy of a write end would keep omp from ever seeing EOF on stdin.
            _ = fcntl(fds[0], F_SETFD, FD_CLOEXEC)
            _ = fcntl(fds[1], F_SETFD, FD_CLOEXEC)
            pipes.append((fds[0], fds[1]))
        }
        return pipes
    }

    private static func setNonBlocking(_ fd: Int32) {
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    }
}
