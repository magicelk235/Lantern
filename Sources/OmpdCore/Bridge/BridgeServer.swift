import Darwin
import Foundation
import IDEProtocol

/// ompd's end of the ide-bridge control channel (`$APP_SUPPORT/run/bridge.sock`).
///
/// Per spawn: `expect(sessionKey:)` mints a fresh single-use token and returns the environment for the omp child, which
/// must be this process's direct child; `setExpectedPID(_:for:)` registers that child's pid once it is running (before
/// or after its first RPC round trip). The bridge inside omp connects at the main session's `session_start` and sends
/// `hello` without blocking omp; the server accepts it only if the token matches (constant time), the session has no
/// bridge yet, and the socket peer (`LOCAL_PEERPID`) is the registered pid. Hellos that arrive before the pid is
/// registered wait for it. Verdicts go back as `{t:"welcome"}` or `{t:"reject", reason}` (the bridge of a rejected
/// process refuses to keep a daemon-owned session open). A session is ready once RPC `ready` and `waitForHello` have
/// both completed.
///
/// Wire: JSON lines. ompd → bridge `{t:"req", id, method, params}`; bridge → ompd `{t:"res", id, ok, result|error}`,
/// `{t:"evt", seq, ts, agentId, kind, data}`, `{t:"gap", ...}`. Requests on one session run concurrently in the bridge.
public actor BridgeServer {
    public static let wireVersion = 1

    public nonisolated let socketPath: String
    private let handshakeTimeout: Duration
    private let maxFrameBytes: Int

    private enum Phase { case idle, running, stopped }

    private var phase = Phase.idle
    private var listener: BridgeListener?
    private var socketFile: SocketFileIdentity?
    private var sessions: [SessionKey: Session] = [:]
    private var peers: [Int: Peer] = [:]
    private var lastPeerID = 0
    private var lastRequestID: UInt64 = 0
    private var lastWaiterID = 0

    private struct Session {
        let token: [UInt8]
        var expectedPID: pid_t?
        var hello: BridgeHello?
        var peerID: Int?
        /// The accepted connection ended; the token is spent, so the session never reconnects.
        var disconnected = false
        var rejectedHellos = 0
        var helloWaiters: [Int: HelloWaiter] = [:]
        var calls: [String: PendingCall] = [:]
        let events: AsyncStream<JSONValue>
        let eventSink: AsyncStream<JSONValue>.Continuation
    }

    private struct HelloWaiter {
        let continuation: CheckedContinuation<BridgeHello, any Error>
        let timer: Task<Void, Never>
    }

    private struct PendingCall {
        let method: String
        let continuation: CheckedContinuation<JSONValue, any Error>
        let timer: Task<Void, Never>
    }

    private struct Peer {
        let connection: BridgeConnection
        var stage: Stage
    }

    private enum Stage {
        case awaitingHello
        /// Token accepted; waiting for `setExpectedPID` of that session.
        case awaitingPID(BridgeHello)
        case accepted(SessionKey)
        /// Rejected or dropped by the server; waiting for the socket to finish closing.
        case closing
    }

    /// - Parameters:
    ///   - socketPath: under 104 bytes; the parent directory should be private (`run/` is 0700).
    ///   - handshakeTimeout: a connection that is not accepted within this time is rejected and closed.
    ///   - maxFrameBytes: longest accepted line; a longer one closes the connection.
    public init(socketPath: String, handshakeTimeout: Duration = .seconds(10), maxFrameBytes: Int = 16 << 20) {
        self.socketPath = socketPath
        self.handshakeTimeout = handshakeTimeout
        self.maxFrameBytes = maxFrameBytes
    }

    deinit {
        listener?.cancel()
    }

    /// Binds the socket (mode 0600) and starts accepting. A leftover socket file nobody listens on is replaced; a live
    /// listener or a non-socket file is left alone and reported.
    public func start() async throws {
        guard phase == .idle else { throw BridgeError.invalidState("BridgeServer.start() after start() or stop()") }
        try BridgeSocket.removeStale(socketPath)
        let fd = try BridgeSocket.listen(path: socketPath)
        socketFile = SocketFileIdentity(path: socketPath)
        listener = BridgeListener(fd: fd) { [weak self] client, peerPID in
            guard let self else {
                _ = Darwin.close(client)
                return
            }
            Task { await self.admit(client, peerPID: peerPID) }
        }
        phase = .running
    }

    /// Stops accepting, closes every bridge connection and removes the socket file. Pending waits and calls fail,
    /// every event stream finishes. Terminal: the server cannot be started again.
    public func stop() async {
        guard phase != .stopped else { return }
        phase = .stopped
        listener?.cancel()
        listener = nil
        if let socketFile, SocketFileIdentity(path: socketPath) == socketFile { unlink(socketPath) }
        socketFile = nil
        let all = sessions
        sessions = [:]
        for session in all.values { tearDown(session) }
        for (id, peer) in peers {
            peers[id]?.stage = .closing
            peer.connection.close()
        }
    }

    /// Registers a spawn: a fresh random token for `sessionKey`, valid for one `hello`. Replaces any previous
    /// registration of the key (closing its connection, failing its waits and calls, finishing its event stream).
    public func expect(sessionKey: SessionKey) -> BridgeCredentials {
        if let previous = sessions.removeValue(forKey: sessionKey) { tearDown(previous, closing: sessionKey) }
        var generator = SystemRandomNumberGenerator()
        let token = (0..<32).map { _ in String(format: "%02x", generator.next() as UInt8) }.joined()
        let (events, sink) = AsyncStream.makeStream(of: JSONValue.self, bufferingPolicy: .unbounded)
        sessions[sessionKey] = Session(token: Array(token.utf8), events: events, eventSink: sink)
        return BridgeCredentials(socketPath: socketPath, sessionKey: sessionKey, token: token, daemonPID: getpid())
    }

    /// The pid of the omp child spawned with `sessionKey`'s credentials. Only a socket peer with this pid can complete
    /// the handshake; a hello already waiting is accepted or rejected now.
    public func setExpectedPID(_ pid: Int32, for sessionKey: SessionKey) {
        guard sessions[sessionKey] != nil else { return }
        sessions[sessionKey]?.expectedPID = pid
        for id in peers.keys.sorted() {
            guard case .awaitingPID(let hello)? = peers[id]?.stage, hello.sessionKey == sessionKey else { continue }
            if hello.pid == pid && sessions[sessionKey]?.peerID == nil {
                accept(id, hello)
            } else {
                reject(id, "peer pid \(hello.pid) is not the omp process ompd spawned", countingAgainst: sessionKey)
            }
        }
    }

    /// The accepted hello of `sessionKey`, waiting up to `timeout` for it.
    /// - Throws: `.notConnected` if the key is not `expect`ed (or gets forgotten meanwhile); on timeout `.unauthorized`
    ///   if a hello for the key was rejected, else `.helloTimeout`.
    public func waitForHello(_ sessionKey: SessionKey, timeout: Duration) async throws -> BridgeHello {
        guard let session = sessions[sessionKey] else { throw BridgeError.notConnected }
        if let hello = session.hello { return hello }
        lastWaiterID += 1
        let waiterID = lastWaiterID
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let timer = Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    guard !Task.isCancelled else { return }
                    await self?.expireHelloWait(sessionKey, waiterID)
                }
                sessions[sessionKey]?.helloWaiters[waiterID] = HelloWaiter(continuation: continuation, timer: timer)
            }
        } onCancel: {
            Task { await self.endHelloWait(sessionKey, waiterID, with: CancellationError()) }
        }
    }

    /// Sends `{t:"req", method, params}` to the session's bridge and returns the `result` of its reply.
    /// - Throws: `.notConnected` before an accepted hello, `.disconnected` once the connection ended (also for calls in
    ///   flight when it ends), `.callFailed` for an `ok: false` reply, `.callTimeout`, or `CancellationError`.
    public func call(
        _ sessionKey: SessionKey, method: String, params: JSONValue = [:], timeout: Duration = .seconds(30)
    ) async throws -> JSONValue {
        guard let session = sessions[sessionKey] else { throw BridgeError.notConnected }
        guard let peerID = session.peerID, let peer = peers[peerID] else {
            throw session.disconnected ? BridgeError.disconnected : BridgeError.notConnected
        }
        lastRequestID += 1
        let id = String(lastRequestID)
        let line = try Self.line(["t": "req", "id": .string(id), "method": .string(method), "params": params])
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let timer = Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    guard !Task.isCancelled else { return }
                    await self?.endCall(sessionKey, id, with: BridgeError.callTimeout(method: method))
                }
                sessions[sessionKey]?.calls[id] = PendingCall(method: method, continuation: continuation, timer: timer)
                peer.connection.send(line)
            }
        } onCancel: {
            Task { await self.endCall(sessionKey, id, with: CancellationError()) }
        }
    }

    /// The session's `evt` and `gap` frames, verbatim and in order, buffered from `expect` on. Single consumer. Finishes
    /// when the bridge disconnects, on `forget`, on a new `expect` for the key, and on `stop`. An unknown key yields an
    /// already finished stream.
    public func events(_ sessionKey: SessionKey) -> AsyncStream<JSONValue> {
        sessions[sessionKey]?.events ?? AsyncStream { $0.finish() }
    }

    /// Drops the session: closes its bridge connection, fails pending waits (`.notConnected`) and calls
    /// (`.disconnected`), finishes its event stream.
    public func forget(_ sessionKey: SessionKey) {
        guard let session = sessions.removeValue(forKey: sessionKey) else { return }
        tearDown(session, closing: sessionKey)
    }

    // MARK: - Connections

    private func admit(_ fd: Int32, peerPID: pid_t?) {
        guard phase == .running else {
            _ = Darwin.close(fd)
            return
        }
        lastPeerID += 1
        let connection = BridgeConnection(fd: fd, id: lastPeerID, peerPID: peerPID, maxLineBytes: maxFrameBytes)
        peers[connection.id] = Peer(connection: connection, stage: .awaitingHello)
        Task { [weak self] in
            for await line in connection.lines { await self?.received(line, from: connection.id) }
            await self?.ended(connection.id)
        }
        connection.start()
        let timeout = handshakeTimeout
        Task { [weak self] in
            try? await Task.sleep(for: timeout)
            await self?.expireHandshake(connection.id)
        }
    }

    private func received(_ line: Data, from id: Int) {
        guard let peer = peers[id] else { return }
        guard case .object(let frame)? = try? JSONDecoder().decode(JSONValue.self, from: line) else {
            switch peer.stage {
            case .awaitingHello, .awaitingPID: return reject(id, "malformed frame")
            case .accepted(let key):
                bridgeLog.error("bridge of \(key, privacy: .public) sent a malformed frame; closing")
                return peer.connection.close()
            case .closing: return
            }
        }
        let type = frame["t"]?.stringValue
        switch peer.stage {
        case .awaitingHello:
            guard type == "hello" else { return reject(id, "the first frame must be hello") }
            hello(frame, from: id)
        case .awaitingPID:
            reject(id, "frame sent before the welcome")
        case .accepted(let key):
            switch type {
            case "res": resolve(frame, session: key)
            case "evt", "gap": sessions[key]?.eventSink.yield(.object(frame))
            default: bridgeLog.notice("ignoring bridge frame \(type ?? "without t", privacy: .public) from \(key, privacy: .public)")
            }
        case .closing:
            break
        }
    }

    private func hello(_ frame: [String: JSONValue], from id: Int) {
        guard let peer = peers[id] else { return }
        guard frame["v"]?.doubleValue == Double(Self.wireVersion) else {
            return reject(id, "unsupported bridge wire version (ompd speaks \(Self.wireVersion))")
        }
        guard let key = frame["sessionKey"]?.stringValue, let session = sessions[key] else {
            return reject(id, "unknown session key")
        }
        guard Self.tokenMatches(session.token, frame["token"]?.stringValue ?? "") else {
            return reject(id, "invalid token", countingAgainst: key)
        }
        guard session.hello == nil, session.peerID == nil, !session.disconnected else {
            return reject(id, "session already had its bridge connection", countingAgainst: key)
        }
        guard let peerPID = peer.connection.peerPID else {
            return reject(id, "the kernel did not report the peer pid", countingAgainst: key)
        }
        let hello: BridgeHello
        do {
            hello = try BridgeHello(frame: frame, peerPID: peerPID)
        } catch {
            return reject(id, "malformed hello: \(error.description)", countingAgainst: key)
        }
        guard let expected = session.expectedPID else {
            peers[id]?.stage = .awaitingPID(hello)
            return
        }
        guard expected == peerPID else {
            return reject(id, "peer pid \(peerPID) is not the omp process ompd spawned", countingAgainst: key)
        }
        accept(id, hello)
    }

    private func accept(_ id: Int, _ hello: BridgeHello) {
        guard let peer = peers[id], sessions[hello.sessionKey] != nil else { return }
        peers[id]?.stage = .accepted(hello.sessionKey)
        sessions[hello.sessionKey]?.peerID = id
        sessions[hello.sessionKey]?.hello = hello
        peer.connection.send(Self.welcomeLine)
        let waiters = sessions[hello.sessionKey]?.helloWaiters ?? [:]
        sessions[hello.sessionKey]?.helloWaiters = [:]
        for waiter in waiters.values {
            waiter.timer.cancel()
            waiter.continuation.resume(returning: hello)
        }
    }

    private func reject(_ id: Int, _ reason: String, countingAgainst sessionKey: SessionKey? = nil) {
        guard let peer = peers[id] else { return }
        bridgeLog.notice("rejecting bridge peer pid \(peer.connection.peerPID ?? -1): \(reason, privacy: .public)")
        if let sessionKey { sessions[sessionKey]?.rejectedHellos += 1 }
        peers[id]?.stage = .closing
        let line = (try? Self.line(["t": "reject", "reason": .string(reason)])) ?? Self.rejectFallbackLine
        peer.connection.send(line, thenClose: true)
    }

    private func expireHandshake(_ id: Int) {
        switch peers[id]?.stage {
        case .awaitingHello?:
            reject(id, "no hello within the handshake timeout")
        case .awaitingPID(let hello)?:
            reject(id, "ompd never registered the pid for session \(hello.sessionKey)", countingAgainst: hello.sessionKey)
        case .accepted?, .closing?, nil:
            break
        }
    }

    private func ended(_ id: Int) {
        guard let peer = peers.removeValue(forKey: id) else { return }
        guard case .accepted(let key) = peer.stage, sessions[key]?.peerID == id else { return }
        sessions[key]?.peerID = nil
        sessions[key]?.disconnected = true
        let calls = sessions[key]?.calls ?? [:]
        sessions[key]?.calls = [:]
        for call in calls.values {
            call.timer.cancel()
            call.continuation.resume(throwing: BridgeError.disconnected)
        }
        sessions[key]?.eventSink.finish()
    }

    /// Fails everything waiting on a session that was removed from `sessions`; with `closing`, also drops its
    /// connections (the accepted one without a verdict, hellos still waiting for their pid with a reject).
    private func tearDown(_ session: Session, closing sessionKey: SessionKey? = nil) {
        for waiter in session.helloWaiters.values {
            waiter.timer.cancel()
            waiter.continuation.resume(throwing: BridgeError.notConnected)
        }
        for call in session.calls.values {
            call.timer.cancel()
            call.continuation.resume(throwing: BridgeError.disconnected)
        }
        session.eventSink.finish()
        guard let sessionKey else { return }
        for id in peers.keys.sorted() {
            switch peers[id]?.stage {
            case .accepted(let key)? where key == sessionKey:
                peers[id]?.stage = .closing
                peers[id]?.connection.close()
            case .awaitingPID(let hello)? where hello.sessionKey == sessionKey:
                reject(id, "ompd dropped session \(sessionKey)")
            default:
                break
            }
        }
    }

    // MARK: - Calls

    private func resolve(_ frame: [String: JSONValue], session sessionKey: SessionKey) {
        guard let id = frame["id"]?.stringValue, let call = sessions[sessionKey]?.calls.removeValue(forKey: id) else {
            return // answer to a call that already timed out or was cancelled
        }
        call.timer.cancel()
        if frame["ok"]?.boolValue == true {
            call.continuation.resume(returning: frame["result"] ?? .null)
        } else {
            let message = frame["error"]?.stringValue ?? frame["error"]?["message"]?.stringValue ?? "no error message"
            call.continuation.resume(throwing: BridgeError.callFailed(method: call.method, message: message))
        }
    }

    private func endCall(_ sessionKey: SessionKey, _ id: String, with error: any Error) {
        guard let call = sessions[sessionKey]?.calls.removeValue(forKey: id) else { return }
        call.timer.cancel()
        call.continuation.resume(throwing: error)
    }

    private func expireHelloWait(_ sessionKey: SessionKey, _ waiterID: Int) {
        let rejected = (sessions[sessionKey]?.rejectedHellos ?? 0) > 0
        endHelloWait(sessionKey, waiterID, with: rejected ? BridgeError.unauthorized : BridgeError.helloTimeout)
    }

    private func endHelloWait(_ sessionKey: SessionKey, _ waiterID: Int, with error: any Error) {
        guard let waiter = sessions[sessionKey]?.helloWaiters.removeValue(forKey: waiterID) else { return }
        waiter.timer.cancel()
        waiter.continuation.resume(throwing: error)
    }

    // MARK: - Encoding

    private static let welcomeLine = Data("{\"t\":\"welcome\",\"v\":\(wireVersion)}\n".utf8)
    private static let rejectFallbackLine = Data("{\"t\":\"reject\",\"reason\":\"rejected\"}\n".utf8)

    private static func line(_ object: [String: JSONValue]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        var data = try encoder.encode(JSONValue.object(object))
        data.append(0x0A)
        return data
    }

    /// Constant time in the candidate's content: always walks the whole expected token.
    private static func tokenMatches(_ expected: [UInt8], _ candidate: String) -> Bool {
        var candidateBytes = candidate.utf8.makeIterator()
        var difference: UInt8 = candidate.utf8.count == expected.count ? 0 : 1
        for byte in expected { difference |= byte ^ (candidateBytes.next() ?? 0) }
        return difference == 0
    }
}
