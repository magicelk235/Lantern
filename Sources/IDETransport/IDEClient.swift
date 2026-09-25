import Foundation
import Network
import os

/// App-side connection to ompd. One instance is one connection: after `close()` or a disconnect, make a new client.
public actor IDEClient {
    /// Every non-response frame (event, resync, ptyOutput, sessions) in arrival order; finishes when the connection
    /// ends. Single consumer. Buffered without bound so the socket keeps draining; the daemon's slow-consumer cutoff
    /// only trips when this process stops reading altogether.
    public nonisolated let pushes: AsyncStream<ServerFrame>

    private let socketPath: String
    private let token: String
    private let clientVersion: String
    private let inbox: ClientInbox
    private var channel: FrameChannel?
    private var phase: Phase = .idle
    private var lastRequestID: UInt64 = 0

    private enum Phase { case idle, connecting, connected, closed }

    public init(socketPath: String, token: String, clientVersion: String) {
        let (pushes, sink) = AsyncStream.makeStream(of: ServerFrame.self)
        self.pushes = pushes
        inbox = ClientInbox(pushes: sink)
        self.socketPath = socketPath
        self.token = token
        self.clientVersion = clientVersion
    }

    deinit {
        channel?.terminate(.local)
        inbox.end(.local)
    }

    /// Connects and performs the handshake. Throws `DaemonError` (`unauthorized`, `versionMismatch`) when the daemon
    /// refuses, `IDETransportError.connectFailed` when no daemon listens, `CancellationError` when cancelled.
    public func connect() async throws -> Welcome {
        guard phase == .idle else {
            throw IDETransportError.invalidState(phase == .closed ? "IDEClient is closed" : "connect() already called")
        }
        try UnixSocket.validate(socketPath)
        let hello = try FrameCodec.encode(ClientFrame.hello(Hello(clientVersion: clientVersion, token: token)))
        phase = .connecting
        let channel = FrameChannel(
            connection: NWConnection(to: .unix(path: socketPath), using: .unixStream()),
            queue: DispatchQueue(label: "com.omp-ide.transport.client"))
        self.channel = channel
        let inbox = inbox
        do {
            let welcome = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Welcome, any Error>) in
                    guard inbox.awaitWelcome(continuation) else { return }
                    channel.start(onFrame: { try inbox.receive($0) }, onEnd: { inbox.end($0) })
                    channel.send(hello)
                }
            } onCancel: {
                inbox.cancelHandshake()
                channel.terminate(.local)
            }
            guard phase == .connecting else { throw IDETransportError.connectionClosed }
            phase = .connected
            return welcome
        } catch {
            phase = .closed
            channel.terminate(.local)
            inbox.end(.local)
            throw error
        }
    }

    /// Sends one request and awaits its response. Throws the daemon's `DaemonError` for error responses,
    /// `IDETransportError.connectionClosed` if the connection ends first, `CancellationError` when cancelled (the
    /// request may still have reached the daemon). Requests are written in call order but served concurrently.
    public func call<M: DaemonMethod>(_ method: M.Type, _ params: M.Params) async throws -> M.Result {
        guard phase == .connected, let channel else { throw IDETransportError.notConnected }
        try Task.checkCancellation()
        lastRequestID += 1
        let id = String(lastRequestID)
        let frame = try FrameCodec.encode(ClientFrame.request(Request(id: id, method: M.name, params: WireJSON.value(params))))
        let inbox = inbox
        let response = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Response, any Error>) in
                if inbox.register(id, continuation) { channel.send(frame) }
            }
        } onCancel: {
            inbox.cancelCall(id)
        }
        guard response.ok else {
            if let error = response.error { throw error }
            throw IDETransportError.protocolViolation("response \(id) failed without an error")
        }
        do {
            return try WireJSON.decode(M.Result.self, from: response.result ?? .null)
        } catch {
            throw IDETransportError.protocolViolation("\(M.name) result does not decode: \(error)")
        }
    }

    /// Drops the connection: pending calls throw `connectionClosed`, `pushes` finishes.
    public func close() {
        phase = .closed
        channel?.terminate(.local)
        inbox.end(.local)
    }
}

/// Routes a client's inbound frames (on the channel queue): the handshake reply to `connect`, responses to their
/// waiting `call`, everything else to `pushes`.
final class ClientInbox: Sendable {
    private let pushes: AsyncStream<ServerFrame>.Continuation
    private let state = OSAllocatedUnfairLock(initialState: State())

    private struct State: Sendable {
        var handshake: CheckedContinuation<Welcome, any Error>?
        var welcomed = false
        var calls: [String: CheckedContinuation<Response, any Error>] = [:]
        var end: ChannelEnd?
    }

    private enum Waiter: Sendable {
        case handshake(CheckedContinuation<Welcome, any Error>?)
        case call(CheckedContinuation<Response, any Error>?)
    }

    init(pushes: AsyncStream<ServerFrame>.Continuation) {
        self.pushes = pushes
    }

    /// Parks `connect`'s continuation. False (continuation already resumed) if cancelled or ended.
    func awaitWelcome(_ continuation: CheckedContinuation<Welcome, any Error>) -> Bool {
        let refusal: (any Error)? = state.withLock { s in
            if Task.isCancelled { return CancellationError() }
            if let end = s.end { return end.handshakeError }
            s.handshake = continuation
            return nil
        }
        guard let refusal else { return true }
        continuation.resume(throwing: refusal)
        return false
    }

    func cancelHandshake() {
        state.withLock { s in
            defer { s.handshake = nil }
            return s.handshake
        }?.resume(throwing: CancellationError())
    }

    /// Parks a call's continuation. False (continuation already resumed) if cancelled or ended.
    func register(_ id: String, _ continuation: CheckedContinuation<Response, any Error>) -> Bool {
        let refusal: (any Error)? = state.withLock { s in
            if Task.isCancelled { return CancellationError() }
            if let end = s.end { return end.callError }
            s.calls[id] = continuation
            return nil
        }
        guard let refusal else { return true }
        continuation.resume(throwing: refusal)
        return false
    }

    func cancelCall(_ id: String) {
        state.withLock { $0.calls.removeValue(forKey: id) }?.resume(throwing: CancellationError())
    }

    func receive(_ bytes: Data) throws {
        let frame: ServerFrame
        do {
            frame = try Coders.decoder.decode(ServerFrame.self, from: bytes)
        } catch {
            throw IDETransportError.protocolViolation("undecodable frame: \(error)")
        }
        switch frame {
        case .welcome(let welcome):
            let waiter = try state.withLock { s in
                guard !s.welcomed else { throw IDETransportError.protocolViolation("second welcome") }
                s.welcomed = true
                defer { s.handshake = nil }
                return s.handshake
            }
            waiter?.resume(returning: welcome)
        case .response(let response):
            let waiter: Waiter = state.withLock { s in
                guard s.welcomed else {
                    defer { s.handshake = nil }
                    return .handshake(s.handshake)
                }
                return .call(s.calls.removeValue(forKey: response.id))
            }
            switch waiter {
            case .handshake(let continuation):
                // Before the welcome, a response can only be the daemon refusing the hello.
                continuation?.resume(throwing: response.error ?? DaemonError(.internal, "handshake refused without an error"))
            case .call(let continuation):
                continuation?.resume(returning: response) // nil: the call was cancelled
            }
        case .event, .resync, .ptyOutput, .sessions:
            pushes.yield(frame)
        }
    }

    /// Fails whatever is still waiting and finishes `pushes`. Idempotent.
    func end(_ reason: ChannelEnd) {
        let (handshake, calls): (CheckedContinuation<Welcome, any Error>?, [CheckedContinuation<Response, any Error>]) =
            state.withLock { s in
                guard s.end == nil else { return (nil, []) }
                s.end = reason
                defer {
                    s.handshake = nil
                    s.calls = [:]
                }
                return (s.handshake, Array(s.calls.values))
            }
        handshake?.resume(throwing: reason.handshakeError)
        for call in calls { call.resume(throwing: reason.callError) }
        pushes.finish()
    }
}

extension ChannelEnd {
    var handshakeError: IDETransportError {
        switch self {
        case .failure(let message): .connectFailed(message)
        case .protocolError(let message): .protocolViolation(message)
        case .local, .peer, .overflow: .connectionClosed
        }
    }

    var callError: IDETransportError {
        if case .protocolError(let message) = self { return .protocolViolation(message) }
        return .connectionClosed
    }
}
