import Foundation
import Network
import os

let transportLog = Logger(subsystem: "com.omp-ide", category: "transport")

/// Why a `FrameChannel` ended. The first cause recorded wins.
enum ChannelEnd: Sendable, Equatable {
    /// Closed by this side.
    case local
    /// The peer closed the stream.
    case peer
    /// The peer fell further behind than the backlog cap allows (slow consumer).
    case overflow
    /// The peer sent bytes that are not valid frames or messages.
    case protocolError(String)
    /// Network.framework / POSIX failure: connect refused, missing socket, reset, ...
    case failure(String)
}

extension NWParameters {
    /// Stream parameters for an AF_UNIX endpoint (the TCP options are inert for unix sockets).
    static func unixStream() -> NWParameters { NWParameters(tls: nil, tcp: NWProtocolTCP.Options()) }
}

/// Length-prefixed frames over one `NWConnection`, both directions.
///
/// Outbound: `send` appends to a FIFO under a lock and never blocks; a single writer on `queue` hands queued frames to
/// Network.framework in batches, so frames hit the socket in the order `send` accepted them. `backlog` counts accepted
/// bytes whose write has not completed; a `send` that would push it past `maxBacklogBytes` tears the channel down
/// (slow-consumer policy), except that a frame is always accepted while nothing is pending.
///
/// Inbound: bytes are split into frames on `queue` and handed to `onFrame` in stream order. A throwing `onFrame`, a
/// framing error, EOF or a socket error ends the channel; `onEnd` then runs exactly once, after Network.framework has
/// torn the connection down.
final class FrameChannel: Sendable {
    static let readChunk = 256 * 1024
    /// How long a graceful `close()` waits for a peer to read what is queued before cutting it off.
    static let closeGrace: DispatchTimeInterval = .seconds(2)

    let connection: NWConnection
    let queue: DispatchQueue
    private let maxBacklogBytes: Int
    private let decoder: OSAllocatedUnfairLock<FrameDecoder>
    private let state = OSAllocatedUnfairLock(initialState: State())

    private struct Waiter: Sendable {
        let id: UInt64
        let limit: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private struct State: Sendable {
        var outbox: [Data] = []
        var flushScheduled = false
        var backlog = 0
        /// Graceful close requested: refuse new frames, cancel once the backlog is written.
        var closing = false
        var end: ChannelEnd?
        var waiters: [Waiter] = []
        var lastWaiterID: UInt64 = 0
    }

    private enum SendOutcome: Sendable { case queued, scheduleFlush, refused, overflow }

    init(connection: NWConnection, queue: DispatchQueue, maxBacklogBytes: Int = .max, maxFrameBytes: Int = ideMaxFrameBytes) {
        self.connection = connection
        self.queue = queue
        self.maxBacklogBytes = maxBacklogBytes
        decoder = OSAllocatedUnfairLock(initialState: FrameDecoder(maxFrameBytes: maxFrameBytes))
    }

    /// Bytes accepted by `send` whose write to the socket has not completed.
    var backlogBytes: Int { state.withLock { $0.backlog } }

    /// False once the channel is closing or closed; lets callers skip encoding frames that would be dropped.
    var isAccepting: Bool { state.withLock { $0.end == nil && !$0.closing } }

    func start(onFrame: @escaping @Sendable (Data) throws -> Void, onEnd: @escaping @Sendable (ChannelEnd) -> Void) {
        connection.stateUpdateHandler = { [self] newState in
            switch newState {
            case .waiting(let error):
                // A missing or refused unix socket shows up as `waiting`, and Network.framework would retry forever.
                terminate(.failure(String(describing: error)))
            case .failed(let error):
                terminate(.failure(String(describing: error)))
            case .cancelled:
                connection.stateUpdateHandler = nil // breaks connection -> handler -> channel
                _ = settle(.local)
                onEnd(state.withLock { $0.end ?? .local })
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive(onFrame)
    }

    /// Queues one encoded frame. Dropped if the channel is closing or closed; tears the channel down if the frame would
    /// overflow the backlog cap.
    func send(_ frame: Data) {
        let outcome: SendOutcome = state.withLock { s in
            guard s.end == nil, !s.closing else { return .refused }
            if s.backlog > 0, frame.count > maxBacklogBytes - s.backlog { return .overflow }
            s.backlog += frame.count
            s.outbox.append(frame)
            if s.flushScheduled { return .queued }
            s.flushScheduled = true
            return .scheduleFlush
        }
        switch outcome {
        case .queued, .refused: break
        case .scheduleFlush: queue.async { [self] in flush() }
        case .overflow: terminate(.overflow)
        }
    }

    /// Refuses further frames, writes out what is queued, then closes. A peer that stops reading is cut off after
    /// `closeGrace`.
    func close() {
        let drained: Bool? = state.withLock { s in
            guard s.end == nil, !s.closing else { return nil }
            s.closing = true
            return s.backlog == 0
        }
        guard let drained else { return }
        if drained {
            if settle(.local) { connection.cancel() }
        } else {
            queue.asyncAfter(deadline: .now() + Self.closeGrace) { [self] in terminate(.local) }
        }
    }

    /// Tears the channel down now, dropping unwritten frames. Idempotent; the first reason is the one reported.
    func terminate(_ reason: ChannelEnd) {
        if settle(reason) { connection.forceCancel() }
    }

    /// Suspends until at most `limit` bytes are pending, the channel ends, or the calling task is cancelled.
    func waitForBacklog(atMost limit: Int) async {
        let id = state.withLock { s in
            s.lastWaiterID += 1
            return s.lastWaiterID
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let parked = state.withLock { s in
                    // Checked under the lock so a concurrent onCancel either sees this waiter or we see the cancel.
                    guard s.end == nil, s.backlog > limit, !Task.isCancelled else { return false }
                    s.waiters.append(Waiter(id: id, limit: limit, continuation: continuation))
                    return true
                }
                if !parked { continuation.resume() }
            }
        } onCancel: {
            let waiter = state.withLock { s -> Waiter? in
                guard let index = s.waiters.firstIndex(where: { $0.id == id }) else { return nil }
                return s.waiters.remove(at: index)
            }
            waiter?.continuation.resume()
        }
    }

    // MARK: - Private

    private func receive(_ onFrame: @escaping @Sendable (Data) throws -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.readChunk) { [self] content, _, isComplete, error in
            if let content, !content.isEmpty {
                do {
                    for frame in try decoder.withLock({ try $0.push(content) }) { try onFrame(frame) }
                } catch IDETransportError.protocolViolation(let message) {
                    terminate(.protocolError(message))
                    return
                } catch {
                    terminate(.protocolError(String(describing: error)))
                    return
                }
            }
            if let error {
                terminate(.failure(String(describing: error)))
            } else if isComplete {
                terminate(.peer)
            } else {
                receive(onFrame)
            }
        }
    }

    /// Hands everything queued so far to Network.framework as one batch. Runs on `queue`, so batches stay in order.
    /// Completions arrive in send order, so the last frame's completion accounts for the whole batch.
    private func flush() {
        let batch: [Data] = state.withLock { s in
            s.flushScheduled = false
            let batch = s.outbox
            s.outbox = []
            return s.end == nil ? batch : []
        }
        guard let last = batch.last else { return }
        let bytes = batch.reduce(0) { $0 + $1.count }
        connection.batch {
            for frame in batch.dropLast() { connection.send(content: frame, completion: .contentProcessed { _ in }) }
            connection.send(content: last, completion: .contentProcessed { [self] error in written(bytes, error) })
        }
    }

    private func written(_ bytes: Int, _ error: NWError?) {
        if let error {
            terminate(.failure(String(describing: error)))
            return
        }
        let (ready, drained): ([Waiter], Bool) = state.withLock { s in
            guard s.end == nil else { return ([], false) }
            s.backlog -= bytes
            let backlog = s.backlog
            var ready: [Waiter] = []
            s.waiters.removeAll { waiter in
                guard waiter.limit >= backlog else { return false }
                ready.append(waiter)
                return true
            }
            return (ready, s.closing && backlog == 0)
        }
        for waiter in ready { waiter.continuation.resume() }
        if drained, settle(.local) { connection.cancel() }
    }

    /// Records the end reason once, drops queued output and releases backlog waiters. False if already ended.
    private func settle(_ reason: ChannelEnd) -> Bool {
        let waiters: [Waiter]? = state.withLock { s in
            guard s.end == nil else { return nil }
            s.end = reason
            s.outbox = []
            s.backlog = 0
            defer { s.waiters = [] }
            return s.waiters
        }
        guard let waiters else { return false }
        for waiter in waiters { waiter.continuation.resume() }
        return true
    }
}
