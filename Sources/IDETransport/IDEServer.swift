import Darwin
import Foundation
import Network
import os

/// The daemon side of the protocol, called by `IDEServer` for authenticated connections only.
public protocol IDERequestHandler: Sendable {
    /// Manifest for the `welcome` frame. Called after the connection is admitted to `IDEServer.broadcast`, so a
    /// manifest change racing the handshake reaches the client either here or as a push right after the welcome.
    func sessionsForWelcome() async -> [SessionManifestEntry]

    /// Answers one request. Requests on a connection run concurrently (a slow `omp` passthrough never holds up
    /// `pty.write`), so the order in which they take effect is unspecified: a client that needs ordering awaits the
    /// previous response first. When the connection closes, in-flight calls are cancelled and their responses dropped.
    func handle(_ request: Request, from connection: IDEConnection) async -> Response

    /// Called exactly once per connection that received its `welcome`, after the socket closed and every `handle`
    /// call for that connection has returned.
    func connectionClosed(_ connection: IDEConnection) async
}

/// Unix-domain-socket listener for the daemon.
///
/// Handshake: the first frame must be `hello` carrying the token (compared in constant time) and
/// `protocolVersion == ideProtocolVersion`; otherwise the server answers with an `unauthorized` / `version_mismatch`
/// error response (id `"hello"`, or the request's id if a request came first) and closes. A connection that sends
/// nothing is dropped after 10 s. On success the server sends `welcome`, then serves requests until either side closes.
public final class IDEServer: Sendable {
    /// Default slow-consumer cutoff: room for one maximum-size frame plus as much again of queued pushes.
    public static let defaultMaxBacklogBytes = 2 * ideMaxFrameBytes
    static let handshakeTimeout: DispatchTimeInterval = .seconds(10)
    static let handshakeResponseID = "hello"

    private let socketPath: String
    private let token: [UInt8]
    private let daemonVersion: String
    private let startedAt: Date
    private let handler: any IDERequestHandler
    private let maxBacklogBytes: Int
    private let queue = DispatchQueue(label: "com.omp-ide.transport.listener")
    private let state = OSAllocatedUnfairLock(initialState: State())

    private struct State: Sendable {
        var phase: Phase = .idle
        var listener: NWListener?
        var socketFile: FileIdentity?
        var members: [UUID: Member] = [:]
        var stopWaiters: [CheckedContinuation<Void, Never>] = []
    }

    private enum Phase: Sendable { case idle, starting, running, stopped }

    private struct Member: Sendable {
        let connection: IDEConnection
        var stage: Stage
    }

    private enum Stage: Sendable {
        case handshaking
        /// Hello accepted, welcome being built; broadcasts are held until the welcome is queued.
        case welcoming(held: [Data])
        case open
    }

    /// - Parameter maxBacklogBytes: slow-consumer cutoff per connection (see `IDEConnection`).
    public init(
        socketPath: String, token: String, daemonVersion: String, startedAt: Date, handler: any IDERequestHandler,
        maxBacklogBytes: Int = IDEServer.defaultMaxBacklogBytes
    ) {
        self.socketPath = socketPath
        self.token = Array(token.utf8)
        self.daemonVersion = daemonVersion
        self.startedAt = startedAt
        self.handler = handler
        self.maxBacklogBytes = maxBacklogBytes
    }

    /// Binds the socket and starts accepting clients. A leftover socket file nobody listens on is replaced; a live
    /// listener (`addressInUse`) or a non-socket file (`socketPathOccupied`) is left alone. The socket is chmod 0600.
    /// May be retried after a failure; not after `stop()`.
    public func start() async throws {
        try state.withLock { s in
            guard s.phase == .idle else { throw IDETransportError.invalidState("IDEServer.start() after start() or stop()") }
            s.phase = .starting
        }
        do {
            try UnixSocket.validate(socketPath)
            try UnixSocket.removeStale(socketPath)
            let listener = try makeListener()
            do {
                try await ready(listener)
                guard chmod(socketPath, 0o600) == 0 else { throw IDETransportError.systemCall("chmod", errno: errno) }
            } catch {
                listener.cancel()
                throw error
            }
            let identity = FileIdentity(path: socketPath)
            let running = state.withLock { s in
                guard s.phase == .starting else { return false }
                s.phase = .running
                s.listener = listener
                s.socketFile = identity
                return true
            }
            guard running else {
                listener.cancel()
                if let identity, FileIdentity(path: socketPath) == identity { unlink(socketPath) }
                throw IDETransportError.invalidState("IDEServer stopped while starting")
            }
        } catch {
            state.withLock { s in if s.phase == .starting { s.phase = .idle } }
            throw error
        }
    }

    /// Stops accepting, closes every connection (queued frames are flushed within a short grace period) and removes
    /// the socket file. Returns once all sockets are closed; `connectionClosed` callbacks may still be running.
    public func stop() async {
        let (listener, connections): (NWListener?, [IDEConnection]) = state.withLock { s in
            guard s.phase != .stopped else { return (nil, []) }
            s.phase = .stopped
            defer { s.listener = nil }
            return (s.listener, s.members.values.map(\.connection))
        }
        if let listener {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                listener.stateUpdateHandler = { if case .cancelled = $0 { continuation.resume() } }
                listener.cancel()
            }
        }
        for connection in connections { connection.close() }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let idle = state.withLock { s in
                guard !s.members.isEmpty else { return true }
                s.stopWaiters.append(continuation)
                return false
            }
            if idle { continuation.resume() }
        }
        if let identity = state.withLock({ s in defer { s.socketFile = nil }; return s.socketFile }),
           FileIdentity(path: socketPath) == identity {
            unlink(socketPath)
        }
    }

    /// Sends `frame` to every client that completed the handshake (e.g. `.sessions` after a manifest change). Encoded
    /// once. A client whose welcome is still being built receives it right after its welcome.
    public func broadcast(_ frame: ServerFrame) {
        let bytes: Data
        do {
            bytes = try FrameCodec.encode(frame)
        } catch {
            transportLog.error("broadcast frame not encodable: \(String(describing: error), privacy: .public)")
            return
        }
        state.withLock { s in
            for (id, member) in s.members {
                switch member.stage {
                case .open: member.connection.channel.send(bytes)
                case .welcoming(let held): s.members[id]?.stage = .welcoming(held: held + [bytes])
                case .handshaking: break
                }
            }
        }
    }

    // MARK: - Listener

    private func makeListener() throws -> NWListener {
        let parameters = NWParameters.unixStream()
        parameters.requiredLocalEndpoint = .unix(path: socketPath)
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw IDETransportError.listenerFailed(String(describing: error))
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return connection.cancel() }
            accept(connection)
        }
        return listener
    }

    private func ready(_ listener: NWListener) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let pending = OSAllocatedUnfairLock<CheckedContinuation<Void, any Error>?>(initialState: continuation)
            listener.stateUpdateHandler = { [socketPath] newState in
                let outcome: Result<Void, any Error>
                switch newState {
                case .ready: outcome = .success(())
                case .waiting(let error), .failed(let error): outcome = .failure(IDETransportError.listenerFailed(String(describing: error)))
                case .cancelled: outcome = .failure(IDETransportError.listenerFailed("cancelled"))
                default: return
                }
                if let waiter = pending.withLock({ c in defer { c = nil }; return c }) {
                    waiter.resume(with: outcome)
                } else if case .failure(let error) = outcome {
                    transportLog.fault("listener on \(socketPath, privacy: .public) died: \(String(describing: error), privacy: .public)")
                }
            }
            listener.start(queue: queue)
        }
    }

    // MARK: - Connections

    private func accept(_ nwConnection: NWConnection) {
        let channel = FrameChannel(
            connection: nwConnection, queue: DispatchQueue(label: "com.omp-ide.transport.connection"),
            maxBacklogBytes: maxBacklogBytes)
        let connection = IDEConnection(channel: channel)
        let admitted = state.withLock { s in
            guard s.phase == .starting || s.phase == .running else { return false }
            s.members[connection.id] = Member(connection: connection, stage: .handshaking)
            return true
        }
        guard admitted else { return nwConnection.cancel() }
        let (frames, sink) = AsyncStream.makeStream(of: ClientFrame.self)
        channel.start(
            onFrame: { bytes in sink.yield(try Coders.decoder.decode(ClientFrame.self, from: bytes)) },
            onEnd: { [weak self] reason in
                sink.finish()
                self?.ended(connection, reason)
            })
        channel.queue.asyncAfter(deadline: .now() + Self.handshakeTimeout) { [weak self] in
            self?.expireHandshake(connection)
        }
        Task { await self.serve(connection, frames: frames) }
    }

    private func serve(_ connection: IDEConnection, frames: AsyncStream<ClientFrame>) async {
        var inbound = frames.makeAsyncIterator()
        guard let first = await inbound.next() else { return }
        guard case .hello(let hello) = first else {
            if case .request(let request) = first {
                reject(connection, responseID: request.id, .unauthorized, "hello required before any request")
            }
            return
        }
        guard tokenMatches(hello.token) else {
            return reject(connection, responseID: Self.handshakeResponseID, .unauthorized, "invalid token")
        }
        guard hello.protocolVersion == ideProtocolVersion else {
            return reject(
                connection, responseID: Self.handshakeResponseID, .versionMismatch,
                "daemon speaks protocol \(ideProtocolVersion), client \(hello.clientVersion) speaks \(hello.protocolVersion)")
        }
        guard beginWelcome(connection) else { return }
        let welcome = Welcome(daemonVersion: daemonVersion, daemonStartedAt: startedAt, sessions: await handler.sessionsForWelcome())
        guard open(connection, welcome: welcome) else { return }

        await withDiscardingTaskGroup { group in
            while let frame = await inbound.next() {
                guard case .request(let request) = frame else {
                    connection.channel.terminate(.protocolError("hello after handshake"))
                    break
                }
                group.addTask { [handler] in
                    connection.send(.response(await handler.handle(request, from: connection)))
                }
            }
            group.cancelAll()
        }
        await handler.connectionClosed(connection)
    }

    /// Constant time in the candidate's content: always walks the whole expected token.
    private func tokenMatches(_ candidate: String) -> Bool {
        var candidateBytes = candidate.utf8.makeIterator()
        var difference: UInt8 = candidate.utf8.count == token.count ? 0 : 1
        for byte in token { difference |= byte ^ (candidateBytes.next() ?? 0) }
        return difference == 0
    }

    private func reject(_ connection: IDEConnection, responseID: String, _ code: DaemonError.Code, _ message: String) {
        transportLog.notice("rejecting client \(connection.id, privacy: .public): \(message, privacy: .public)")
        connection.send(.response(Response(id: responseID, error: DaemonError(code, message))))
        connection.close()
    }

    private func beginWelcome(_ connection: IDEConnection) -> Bool {
        state.withLock { s in
            guard s.members[connection.id] != nil else { return false }
            s.members[connection.id]?.stage = .welcoming(held: [])
            return true
        }
    }

    /// Queues the welcome followed by any broadcasts held meanwhile, and admits the connection to broadcasts, all under
    /// the server lock so no broadcast can overtake the welcome.
    private func open(_ connection: IDEConnection, welcome: Welcome) -> Bool {
        let bytes: Data
        do {
            bytes = try FrameCodec.encode(ServerFrame.welcome(welcome))
        } catch {
            transportLog.error("welcome not encodable: \(String(describing: error), privacy: .public)")
            connection.channel.terminate(.local)
            return false
        }
        return state.withLock { s in
            guard case .welcoming(let held)? = s.members[connection.id]?.stage else { return false }
            connection.channel.send(bytes)
            for frame in held { connection.channel.send(frame) }
            s.members[connection.id]?.stage = .open
            return true
        }
    }

    private func expireHandshake(_ connection: IDEConnection) {
        let stalled = state.withLock { s in
            guard case .handshaking? = s.members[connection.id]?.stage else { return false }
            return true
        }
        if stalled { connection.channel.terminate(.protocolError("no hello within the handshake timeout")) }
    }

    private func ended(_ connection: IDEConnection, _ reason: ChannelEnd) {
        switch reason {
        case .overflow:
            transportLog.notice("client \(connection.id, privacy: .public) fell over \(self.maxBacklogBytes) bytes behind; disconnected")
        case .protocolError(let message):
            transportLog.error("client \(connection.id, privacy: .public) violated the protocol: \(message, privacy: .public)")
        case .failure(let message):
            transportLog.info("client \(connection.id, privacy: .public) connection failed: \(message, privacy: .public)")
        case .local, .peer:
            break
        }
        let waiters: [CheckedContinuation<Void, Never>] = state.withLock { s in
            s.members[connection.id] = nil
            guard s.phase == .stopped, s.members.isEmpty else { return [] }
            defer { s.stopWaiters = [] }
            return s.stopWaiters
        }
        for waiter in waiters { waiter.resume() }
    }
}

/// Device + inode of the socket file this server bound, so `stop()` never unlinks a successor's socket.
struct FileIdentity: Sendable, Equatable {
    let device: dev_t
    let inode: ino_t

    init?(path: String) {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        device = info.st_dev
        inode = info.st_ino
    }
}

enum UnixSocket {
    /// `sun_path` capacity, including the terminating NUL.
    static let pathCapacity = MemoryLayout.size(ofValue: sockaddr_un().sun_path)

    static func validate(_ path: String) throws {
        guard path.utf8.count < pathCapacity else { throw IDETransportError.socketPathTooLong(path: path) }
    }

    /// Removes a socket file left behind by a dead listener. Never deletes a non-socket or a socket someone listens on.
    static func removeStale(_ path: String) throws {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            if errno == ENOENT { return }
            throw IDETransportError.systemCall("lstat", errno: errno)
        }
        guard info.st_mode & S_IFMT == S_IFSOCK else { throw IDETransportError.socketPathOccupied(path: path) }
        guard try !isListening(path) else { throw IDETransportError.addressInUse(path: path) }
        guard unlink(path) == 0 || errno == ENOENT else { throw IDETransportError.systemCall("unlink", errno: errno) }
    }

    /// Probes `path` with a non-blocking connect. Only "refused" / "gone" count as nobody listening.
    static func isListening(_ path: String) throws -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw IDETransportError.systemCall("socket", errno: errno) }
        defer { Darwin.close(fd) }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path.utf8) }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if result == 0 { return true }
        let error = errno
        return error != ECONNREFUSED && error != ENOENT
    }
}
