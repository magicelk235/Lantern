import Darwin
import Foundation
import IDEProtocol

/// ompd's end of the ide-bridge control channel (`$APP_SUPPORT/run/bridge.sock`).
///
/// Per spawn: `expect(sessionKey:)` mints a fresh random token and returns the environment for the omp child, which must
/// be this process's direct child; `setExpectedPID(_:for:)` registers that child's pid once it is running. The bridge
/// inside omp connects at the main session's `session_start` and sends `hello` without blocking omp; the server accepts
/// it only if the token matches (constant time), the session has no live bridge connection, and the socket peer
/// (`LOCAL_PEERPID`) is the registered pid. Hellos that arrive before the pid is registered wait for it. Verdicts go
/// back as `{t:"welcome"}` or `{t:"reject", reason}` (the bridge of a rejected process refuses to keep a daemon-owned
/// session open).
///
/// Per terminal PTY: `expectTerminal(ptyId:)` mints the token of `TerminalCredentials`, good for every omp the user
/// starts in that terminal until `forgetTerminal`. A hello naming a `ptyId` and that token (the bridge's terminal mode)
/// is handed to ompd through `terminalHellos()` once token and peer pid checked out; ompd's `adoptTerminalHello`
/// registers the omp as the bridge of a session key of its choosing (`welcome`), `refuseTerminalHello` rejects it.
///
/// Redial: when a session's connection ends while its omp lives (ompd upgraded itself in place, or the
/// connection dropped), the same omp says hello again with the same credentials and is accepted again under the same
/// key (`waitForRedial`); each connection has an event stream of its own. `quiesce` ends every connection without losing
/// an event (an in-place upgrade), `handoverState` and `restore` carry the credentials into the next image.
///
/// Wire: JSON lines. ompd → bridge `{t:"req", id, method, params}`; bridge → ompd `{t:"res", id, ok, result|error}`,
/// `{t:"evt", seq, ts, agentId, kind, data}`, `{t:"gap", ...}`. Requests on one session run concurrently in the bridge.
public actor BridgeServer {
    public static let wireVersion = 1

    public nonisolated let socketPath: String
    private let handshakeTimeout: Duration
    private let maxFrameBytes: Int

    private enum Phase {
        case idle, running
        /// `quiesce`: not listening, the credentials kept for the bridges' redials.
        case quiesced
        case stopped
    }

    private var phase = Phase.idle
    private var listener: BridgeListener?
    private var socketFile: SocketFileIdentity?
    private var sessions: [SessionKey: Session] = [:]
    /// Token per terminal PTY (`expectTerminal`).
    private var terminals: [PTYID: [UInt8]] = [:]
    private var peers: [Int: Peer] = [:]
    private var lastPeerID = 0
    private var lastRequestID: UInt64 = 0
    private var lastWaiterID = 0
    /// `quiesce` calls waiting for the last connection to end.
    private var quiesceWaiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private let terminalHelloStream: AsyncStream<TerminalHello>
    private let terminalHelloSink: AsyncStream<TerminalHello>.Continuation

    private struct Session {
        let token: [UInt8]
        var expectedPID: pid_t?
        /// The hello of the newest accepted connection (kept after it ended).
        var hello: BridgeHello?
        var peerID: Int?
        /// The accepted connection ended: the same omp may say hello again with the same token (redial).
        var disconnected = false
        /// An adopted omp: the terminal it was started in, whose credentials its redials carry.
        var terminal: PTYID?
        var rejectedHellos = 0
        var helloWaiters: [Int: HelloWaiter] = [:]
        /// `waitForRedial` calls waiting for the next connection.
        var redialWaiters: [Int: CheckedContinuation<BridgeHello, any Error>] = [:]
        var calls: [String: PendingCall] = [:]
        /// The current (or newest) connection's events; the first from `expect` on, each redial's from its welcome.
        var events: AsyncStream<JSONValue>
        var eventSink: AsyncStream<JSONValue>.Continuation
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
        /// A terminal's token accepted; waiting for ompd's verdict on the `TerminalHello`.
        case adopting(PTYID)
        case accepted(SessionKey)
        /// `quiesce`: ompd stopped writing; what the bridge still sends is read up to its close.
        case draining(SessionKey)
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
        (terminalHelloStream, terminalHelloSink) = AsyncStream.makeStream(of: TerminalHello.self, bufferingPolicy: .unbounded)
    }

    deinit {
        listener?.cancel()
    }

    /// Binds the socket (mode 0600) and starts accepting. A leftover socket file nobody listens on is replaced; a live
    /// listener or a non-socket file is left alone and reported.
    public func start() async throws {
        guard phase == .idle else { throw BridgeError.invalidState("BridgeServer.start() after start() or stop()") }
        try listen()
    }

    private func listen() throws {
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
        stopListening()
        let all = sessions
        sessions = [:]
        terminals = [:]
        for session in all.values { tearDown(session) }
        for (id, peer) in peers {
            peers[id]?.stage = .closing
            peer.connection.close()
        }
        terminalHelloSink.finish()
    }

    private func stopListening() {
        listener?.cancel()
        listener = nil
        if let socketFile, SocketFileIdentity(path: socketPath) == socketFile { unlink(socketPath) }
        socketFile = nil
    }

    // MARK: - In-place upgrade

    /// Stops accepting (the socket file goes) and ends every bridge connection without losing an event: ompd stops
    /// writing (`shutdown(SHUT_WR)`), the bridge reads the end of its input, sends what it still had and closes, and
    /// ompd reads up to that close, so each session's stream delivers everything its bridge sent and then finishes.
    /// Calls fail with `disconnected` from now on; connections still in their handshake are closed. True when every
    /// connection ended within `timeout`. The credentials stay: the same omps say hello again to `resumeListening`, or to
    /// the next image (`handoverState`).
    public func quiesce(timeout: Duration) async -> Bool {
        guard phase == .running else { return peers.isEmpty }
        phase = .quiesced
        stopListening()
        for id in peers.keys.sorted() {
            guard let peer = peers[id] else { continue }
            switch peer.stage {
            case .accepted(let key):
                peers[id]?.stage = .draining(key)
                failCalls(of: key)
                peer.connection.finishWriting()
            case .draining:
                break
            case .awaitingHello, .awaitingPID, .adopting, .closing:
                peers[id]?.stage = .closing
                peer.connection.close()
            }
        }
        guard !peers.isEmpty else { return true }
        lastWaiterID += 1
        let waiterID = lastWaiterID
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            await self?.endQuiesceWait(waiterID)
        }
        await withCheckedContinuation { quiesceWaiters[waiterID] = $0 }
        timer.cancel()
        return peers.isEmpty
    }

    /// Listens again after `quiesce` (the handover did not happen): the bridges redial with their credentials.
    public func resumeListening() throws {
        guard phase == .quiesced else { return }
        try listen()
    }

    /// The credentials of every session and terminal, for the next image (`restore`).
    public func handoverState() -> BridgeHandover {
        BridgeHandover(
            sessions: sessions.compactMap { key, session in
                session.expectedPID.map {
                    BridgeHandover.Session(
                        sessionKey: key, token: String(decoding: session.token, as: UTF8.self), pid: $0, terminal: session.terminal)
                }
            },
            terminals: terminals.mapValues { String(decoding: $0, as: UTF8.self) })
    }

    /// The next image of an in-place upgrade, before `start`: the previous image's sessions, whose bridges redial with
    /// the same credentials (`waitForRedial`), and its terminals' tokens.
    func restore(_ handover: BridgeHandover) {
        for session in handover.sessions {
            let (events, sink) = AsyncStream.makeStream(of: JSONValue.self, bufferingPolicy: .unbounded)
            sink.finish() // the redial's welcome opens the stream its events go to
            sessions[session.sessionKey] = Session(
                token: Array(session.token.utf8), expectedPID: session.pid, disconnected: true, terminal: session.terminal,
                events: events, eventSink: sink)
        }
        for (ptyId, token) in handover.terminals { terminals[ptyId] = Array(token.utf8) }
    }

    private func endQuiesceWait(_ waiterID: Int) {
        quiesceWaiters.removeValue(forKey: waiterID)?.resume()
    }

    // MARK: - Sessions

    /// Registers a spawn: a fresh random token for `sessionKey`, good for the hellos of the one process registered with
    /// `setExpectedPID` (its first, and its redials). Replaces any previous registration of the key (closing its
    /// connection, failing its waits and calls, finishing its event stream).
    public func expect(sessionKey: SessionKey) -> BridgeCredentials {
        if let previous = sessions.removeValue(forKey: sessionKey) { tearDown(previous, closing: sessionKey) }
        let token = Self.mintToken()
        let (events, sink) = AsyncStream.makeStream(of: JSONValue.self, bufferingPolicy: .unbounded)
        sessions[sessionKey] = Session(token: Array(token.utf8), events: events, eventSink: sink)
        return BridgeCredentials(socketPath: socketPath, sessionKey: sessionKey, token: token, daemonPID: getpid())
    }

    /// Registers a terminal PTY: a fresh random token for `ptyId`, good for any number of hellos (one omp at a time is
    /// ompd's decision) until `forgetTerminal`. Replaces the PTY's previous token.
    public func expectTerminal(ptyId: PTYID) -> TerminalCredentials {
        let token = Self.mintToken()
        terminals[ptyId] = Array(token.utf8)
        return TerminalCredentials(socketPath: socketPath, ptyId: ptyId, token: token, daemonPID: getpid())
    }

    /// The terminal PTY is gone: its token is void, and hellos from it still awaiting a verdict are rejected.
    public func forgetTerminal(ptyId: PTYID) {
        terminals[ptyId] = nil
        for id in peers.keys.sorted() {
            if case .adopting(let pty)? = peers[id]?.stage, pty == ptyId { reject(id, "terminal \(ptyId) closed") }
        }
    }

    /// Hellos from terminal-mode bridges whose token and peer pid checked out, in arrival order, each waiting for
    /// `adoptTerminalHello` or `refuseTerminalHello`. Single consumer; finishes on `stop`. An adopted omp's redial is
    /// not one: it is served under its session's key at once.
    public func terminalHellos() -> AsyncStream<TerminalHello> {
        terminalHelloStream
    }

    /// The omp of `hello` is session `sessionKey`'s bridge from now on: its events and calls go by that key (a previous
    /// registration of the key is dropped as by `expect`) and it gets its `welcome`. Returns the hello as registered
    /// (`sessionKey` set), or nil when the connection ended before the verdict.
    public func adoptTerminalHello(_ hello: TerminalHello, as sessionKey: SessionKey) -> BridgeHello? {
        guard let peer = peers[hello.peerID], case .adopting(let ptyId) = peer.stage, ptyId == hello.ptyId else { return nil }
        if let previous = sessions.removeValue(forKey: sessionKey) { tearDown(previous, closing: sessionKey) }
        var accepted = hello.hello
        accepted.sessionKey = sessionKey
        let (events, sink) = AsyncStream.makeStream(of: JSONValue.self, bufferingPolicy: .unbounded)
        sessions[sessionKey] = Session(
            token: Array(Self.mintToken().utf8), expectedPID: accepted.pid, hello: accepted, peerID: hello.peerID,
            terminal: ptyId, events: events, eventSink: sink)
        peers[hello.peerID]?.stage = .accepted(sessionKey)
        peer.connection.send(Self.welcomeLine)
        return accepted
    }

    /// Turns the omp of `hello` away with `reason` (`reject`). A no-op once the verdict was given or the peer left.
    public func refuseTerminalHello(_ hello: TerminalHello, reason: String) {
        guard case .adopting(let ptyId)? = peers[hello.peerID]?.stage, ptyId == hello.ptyId else { return }
        reject(hello.peerID, reason)
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

    /// The accepted hello of `sessionKey` (the newest connection's), waiting up to `timeout` for the first.
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

    /// The hello of `sessionKey`'s bridge once it is connected again after its last connection ended (its omp redials
    /// with the same credentials); the current connection's while one is up. No deadline: the wait ends with
    /// `notConnected` when the key is forgotten (its omp exited), registered again, or the server stops.
    public func waitForRedial(_ sessionKey: SessionKey) async throws -> BridgeHello {
        guard let session = sessions[sessionKey] else { throw BridgeError.notConnected }
        if let peerID = session.peerID, case .accepted? = peers[peerID]?.stage, let hello = session.hello { return hello }
        lastWaiterID += 1
        let waiterID = lastWaiterID
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                sessions[sessionKey]?.redialWaiters[waiterID] = continuation
            }
        } onCancel: {
            Task { await self.endRedialWait(sessionKey, waiterID) }
        }
    }

    /// Sends `{t:"req", method, params}` to the session's bridge and returns the `result` of its reply.
    /// - Throws: `.notConnected` before an accepted hello, `.disconnected` while the connection is down (also for calls in
    ///   flight when it ends), `.callFailed` for an `ok: false` reply, `.callTimeout`, or `CancellationError`.
    public func call(
        _ sessionKey: SessionKey, method: String, params: JSONValue = [:], timeout: Duration = .seconds(30)
    ) async throws -> JSONValue {
        guard let session = sessions[sessionKey] else { throw BridgeError.notConnected }
        guard let peerID = session.peerID, let peer = peers[peerID], case .accepted = peer.stage else {
            throw session.disconnected || session.peerID != nil ? BridgeError.disconnected : BridgeError.notConnected
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

    /// The session's `evt` and `gap` frames of its current connection (the newest, once it ended), verbatim and in
    /// order: the first connection's buffered from `expect` on, a redial's from its welcome. Single consumer. Finishes
    /// when that connection ends, on `forget`, on a new `expect` for the key, and on `stop`. An unknown key yields an
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
            case .awaitingHello, .awaitingPID, .adopting: return reject(id, "malformed frame")
            case .accepted(let key), .draining(let key):
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
        case .awaitingPID, .adopting:
            reject(id, "frame sent before the welcome")
        case .accepted(let key), .draining(let key):
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
        guard let key = frame["sessionKey"]?.stringValue else {
            guard let ptyId = frame["ptyId"]?.stringValue else { return reject(id, "hello names neither a session key nor a terminal") }
            return terminalHello(frame, ptyId: ptyId, from: id, peer: peer)
        }
        guard let session = sessions[key] else {
            return reject(id, "unknown session key")
        }
        guard Self.tokenMatches(session.token, frame["token"]?.stringValue ?? "") else {
            return reject(id, "invalid token", countingAgainst: key)
        }
        guard session.peerID == nil else {
            return reject(id, "session already has its bridge connection", countingAgainst: key)
        }
        guard let peerPID = peer.connection.peerPID else {
            return reject(id, "the kernel did not report the peer pid", countingAgainst: key)
        }
        let hello: BridgeHello
        do {
            hello = try BridgeHello(frame: frame, sessionKey: key, peerPID: peerPID)
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

    /// A terminal-mode hello: the terminal's token and the peer pid must check out. An adopted omp's redial is served
    /// under its session's key at once; any other hello waits for ompd's verdict.
    private func terminalHello(_ frame: [String: JSONValue], ptyId: PTYID, from id: Int, peer: Peer) {
        guard let token = terminals[ptyId] else { return reject(id, "unknown terminal") }
        guard Self.tokenMatches(token, frame["token"]?.stringValue ?? "") else { return reject(id, "invalid token") }
        guard let peerPID = peer.connection.peerPID else { return reject(id, "the kernel did not report the peer pid") }
        var hello: BridgeHello
        do {
            hello = try BridgeHello(frame: frame, sessionKey: "", peerPID: peerPID)
        } catch {
            return reject(id, "malformed hello: \(error.description)")
        }
        let redialed = sessions.first { $0.value.terminal == ptyId && $0.value.expectedPID == peerPID && $0.value.peerID == nil }
        if let key = redialed?.key {
            hello.sessionKey = key
            return accept(id, hello)
        }
        peers[id]?.stage = .adopting(ptyId)
        terminalHelloSink.yield(TerminalHello(ptyId: ptyId, hello: hello, peerID: id))
    }

    /// Welcomes the connection as the session's bridge. A redial's connection gets a new event stream.
    private func accept(_ id: Int, _ hello: BridgeHello) {
        guard let peer = peers[id], var session = sessions[hello.sessionKey] else { return }
        if session.disconnected {
            (session.events, session.eventSink) = AsyncStream.makeStream(of: JSONValue.self, bufferingPolicy: .unbounded)
            session.disconnected = false
        }
        session.peerID = id
        session.hello = hello
        let helloWaiters = session.helloWaiters
        let redialWaiters = session.redialWaiters
        session.helloWaiters = [:]
        session.redialWaiters = [:]
        sessions[hello.sessionKey] = session
        peers[id]?.stage = .accepted(hello.sessionKey)
        peer.connection.send(Self.welcomeLine)
        for waiter in helloWaiters.values {
            waiter.timer.cancel()
            waiter.continuation.resume(returning: hello)
        }
        for waiter in redialWaiters.values { waiter.resume(returning: hello) }
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
        case .adopting(let ptyId)?:
            reject(id, "ompd gave no verdict on the omp in terminal \(ptyId) within the handshake timeout")
        case .accepted?, .draining?, .closing?, nil:
            break
        }
    }

    private func ended(_ id: Int) {
        guard let peer = peers.removeValue(forKey: id) else { return }
        defer {
            if peers.isEmpty {
                let waiters = quiesceWaiters
                quiesceWaiters = [:]
                for waiter in waiters.values { waiter.resume() }
            }
        }
        let key: SessionKey
        switch peer.stage {
        case .accepted(let accepted), .draining(let accepted): key = accepted
        case .awaitingHello, .awaitingPID, .adopting, .closing: return
        }
        guard sessions[key]?.peerID == id else { return }
        sessions[key]?.peerID = nil
        sessions[key]?.disconnected = true
        failCalls(of: key)
        sessions[key]?.eventSink.finish()
    }

    private func failCalls(of sessionKey: SessionKey) {
        let calls = sessions[sessionKey]?.calls ?? [:]
        sessions[sessionKey]?.calls = [:]
        for call in calls.values {
            call.timer.cancel()
            call.continuation.resume(throwing: BridgeError.disconnected)
        }
    }

    /// Fails everything waiting on a session that was removed from `sessions`; with `closing`, also drops its
    /// connections (the accepted one without a verdict, hellos still waiting for their pid with a reject).
    private func tearDown(_ session: Session, closing sessionKey: SessionKey? = nil) {
        for waiter in session.helloWaiters.values {
            waiter.timer.cancel()
            waiter.continuation.resume(throwing: BridgeError.notConnected)
        }
        for waiter in session.redialWaiters.values { waiter.resume(throwing: BridgeError.notConnected) }
        for call in session.calls.values {
            call.timer.cancel()
            call.continuation.resume(throwing: BridgeError.disconnected)
        }
        session.eventSink.finish()
        guard let sessionKey else { return }
        for id in peers.keys.sorted() {
            switch peers[id]?.stage {
            case .accepted(let key)? where key == sessionKey, .draining(let key)? where key == sessionKey:
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

    private func endRedialWait(_ sessionKey: SessionKey, _ waiterID: Int) {
        sessions[sessionKey]?.redialWaiters.removeValue(forKey: waiterID)?.resume(throwing: CancellationError())
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

    /// 32 random bytes as 64 hex characters.
    private static func mintToken() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<32).map { _ in String(format: "%02x", generator.next() as UInt8) }.joined()
    }

    /// Constant time in the candidate's content: always walks the whole expected token.
    private static func tokenMatches(_ expected: [UInt8], _ candidate: String) -> Bool {
        var candidateBytes = candidate.utf8.makeIterator()
        var difference: UInt8 = candidate.utf8.count == expected.count ? 0 : 1
        for byte in expected { difference |= byte ^ (candidateBytes.next() ?? 0) }
        return difference == 0
    }
}
