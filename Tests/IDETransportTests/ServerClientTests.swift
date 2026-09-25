import Darwin
import Foundation
import IDETransport
import os
import Testing

/// Calls a registered method with params that cannot decode into `PTYWrite.Params`.
private enum MalformedPTYWrite: DaemonMethod {
    static let name = PTYWrite.name
    typealias Params = [String: Int]
    typealias Result = Empty
}

private func emitOutputRoute(_ handler: TestHandler) {
    handler.router.on(EmitOutput.self) { params, connection in
        for seq in 1 ... params.count {
            connection.send(.ptyOutput(PTYOutput(ptyId: params.ptyId, data: Data(String(seq).utf8))))
        }
        return Empty()
    }
}

/// Registers `Flood`; every finished flood loop reports how long its `send`s took.
private func floodRoute(_ handler: TestHandler) -> AsyncStream<Duration> {
    let (durations, sink) = AsyncStream.makeStream(of: Duration.self)
    handler.router.on(Flood.self) { params, connection in
        let clock = ContinuousClock()
        let start = clock.now
        let chunk = Data(repeating: 0x61, count: params.bytesPerFrame)
        for _ in 0 ..< params.frames {
            if let limit = params.pacedAtMost { await connection.waitForBacklog(atMost: limit) }
            connection.send(.ptyOutput(PTYOutput(ptyId: "p1", data: chunk)))
        }
        sink.yield(clock.now - start)
        return Empty()
    }
    return durations
}

@Suite(.timeLimit(.minutes(2)))
struct ServerClientTests {
    // MARK: - Handshake

    @Test func welcomeCarriesDaemonIdentityAndManifest() async throws {
        let handler = TestHandler(welcome: { [manifestEntry("s1"), manifestEntry("s2")] })
        try await withServer(handler) { _, path in
            let client = IDEClient(socketPath: path, token: testToken, clientVersion: "app-test")
            let welcome = try await client.connect()
            #expect(welcome == Welcome(
                daemonVersion: "ompd-test", daemonStartedAt: testStartedAt, sessions: [manifestEntry("s1"), manifestEntry("s2")]))
            await client.close()
        }
    }

    enum Refusal: CaseIterable, Sendable {
        case badToken, versionMismatch, requestBeforeHello

        var firstFrame: ClientFrame {
            switch self {
            case .badToken: .hello(Hello(clientVersion: "raw-test", token: "not-the-token"))
            case .versionMismatch: .hello(Hello(protocolVersion: ideProtocolVersion + 1, clientVersion: "raw-test", token: testToken))
            case .requestBeforeHello: .request(Request(id: "42", method: ListSessions.name, params: [:]))
            }
        }

        var expected: (id: String, code: DaemonError.Code) {
            switch self {
            case .badToken: ("hello", .unauthorized)
            case .versionMismatch: ("hello", .versionMismatch)
            case .requestBeforeHello: ("42", .unauthorized)
            }
        }
    }

    @Test(arguments: Refusal.allCases)
    func refusedHandshakeGetsAnErrorResponseThenEOF(_ refusal: Refusal) async throws {
        let handler = TestHandler()
        handler.router.on(ListSessions.self) { _, _ in SessionList(sessions: []) }
        try await withServer(handler) { _, path in
            let raw = try RawClient(path: path)
            try raw.send(refusal.firstFrame)
            guard case .response(let response)? = try await raw.next() else {
                Issue.record("expected an error response")
                return
            }
            #expect(response.id == refusal.expected.id)
            #expect(!response.ok)
            #expect(response.error?.code == refusal.expected.code)
            #expect(try await raw.next() == nil, "server must close after refusing")
        }
    }

    @Test func clientSurfacesRefusalAsDaemonError() async throws {
        try await withServer(TestHandler()) { _, path in
            let client = IDEClient(socketPath: path, token: "not-the-token", clientVersion: "app-test")
            let error = await #expect(throws: DaemonError.self) { try await client.connect() }
            #expect(error?.code == .unauthorized)
            await #expect(throws: IDETransportError.notConnected) { try await client.call(ListSessions.self, Empty()) }
        }
    }

    @Test func connectFailsFastWhenNoDaemonListens() async throws {
        let client = IDEClient(socketPath: tempSocketPath(), token: testToken, clientVersion: "app-test")
        let error = try await within("connect to fail", timeout: 5) {
            await #expect(throws: IDETransportError.self) { try await client.connect() }
        }
        guard case .connectFailed? = error else {
            Issue.record("expected connectFailed, got \(String(describing: error))")
            return
        }
    }

    // MARK: - Socket file

    @Test func socketFileIsOwnerOnly() async throws {
        try await withServer(TestHandler()) { _, path in
            var info = stat()
            #expect(lstat(path, &info) == 0)
            #expect(info.st_mode & S_IFMT == S_IFSOCK)
            #expect(info.st_mode & 0o777 == 0o600)
        }
    }

    @Test func startReplacesAStaleSocketButNeverALiveOneOrAFile() async throws {
        let path = tempSocketPath()
        defer { unlink(path) }
        try bindAndAbandon(path)

        let first = IDEServer(socketPath: path, token: testToken, daemonVersion: "a", startedAt: testStartedAt, handler: TestHandler())
        try await first.start()
        let second = IDEServer(socketPath: path, token: testToken, daemonVersion: "b", startedAt: testStartedAt, handler: TestHandler())
        await #expect(throws: IDETransportError.addressInUse(path: path)) { try await second.start() }
        let client = try await connectedClient(path) // the first server still owns the path
        await client.close()
        await first.stop()
        #expect(access(path, F_OK) != 0, "stop() removes its socket file")

        #expect(FileManager.default.createFile(atPath: path, contents: Data("keep".utf8)))
        let third = IDEServer(socketPath: path, token: testToken, daemonVersion: "c", startedAt: testStartedAt, handler: TestHandler())
        await #expect(throws: IDETransportError.socketPathOccupied(path: path)) { try await third.start() }
        #expect(FileManager.default.contents(atPath: path) == Data("keep".utf8))
    }

    // MARK: - Requests

    @Test func typedMethodsRoundTripThroughTheRouter() async throws {
        let handler = TestHandler()
        let writes = Recorder<PTYWrite.Params>()
        let sessionPTY = PTYInfo(
            ptyId: "p1", cwd: "/tmp/ws2", command: ["/opt/homebrew/bin/omp"], cols: 132, rows: 43, pid: 4242, running: true,
            sessionKey: "created")
        let status = DaemonStatus.Result(
            daemonVersion: "ompd-test", pid: 4242, startedAt: testStartedAt, readOnly: false, sessions: [manifestEntry("s1")],
            ptys: [PTYInfo(ptyId: "t1", cwd: "/tmp", command: ["/bin/zsh", "-l"], cols: 80, rows: 24, pid: nil, running: true), sessionPTY])
        let screen = Data([0x1B, 0x5B, 0x48, 0x00, 0xFF, 0x0A])
        handler.router.on(DaemonStatus.self) { _, _ in status }
        handler.router.on(SessionCreate.self) { params, _ in
            var entry = manifestEntry("created")
            entry.workspace = params.workspace
            entry.launch.approvalMode = params.approvalMode
            entry.launch.model = params.model
            entry.ptyId = "p\(params.cols)x\(params.rows)"
            return entry
        }
        handler.router.on(PTYAttach.self) { params, _ in
            PTYAttach.Result(info: sessionPTY, screen: params.ptyId == sessionPTY.ptyId ? screen : Data())
        }
        handler.router.on(PTYWrite.self) { params, _ in
            await writes.append(params)
            return Empty()
        }

        try await withServer(handler) { _, path in
            let client = try await connectedClient(path)
            #expect(try await client.call(DaemonStatus.self, Empty()) == status)

            let created = try await client.call(
                SessionCreate.self, .init(workspace: "/tmp/ws2", approvalMode: "always-ask", cols: 132, rows: 43))
            #expect(created.workspace == "/tmp/ws2")
            #expect(created.launch.approvalMode == "always-ask")
            #expect(created.launch.model == nil)
            #expect(created.ptyId == "p132x43")

            #expect(try await client.call(PTYAttach.self, .init(ptyId: "p1")) == PTYAttach.Result(info: sessionPTY, screen: screen))

            let bytes = Data([0x00, 0xFF, 0x1B, 0x5B, 0x41, 0x0A])
            _ = try await client.call(PTYWrite.self, .init(ptyId: "p1", data: bytes))
            #expect(await writes.values == [PTYWrite.Params(ptyId: "p1", data: bytes)])
            await client.close()
        }
    }

    @Test func routerMapsFailuresToDaemonErrors() async throws {
        let handler = TestHandler()
        handler.router.on(PTYWrite.self) { _, _ in Empty() }
        handler.router.on(PTYClose.self) { params, _ in throw DaemonError(.noSuchPTY, "no pty \(params.ptyId)") }
        handler.router.on(PTYResize.self) { _, _ in throw CocoaError(.fileNoSuchFile) }

        try await withServer(handler) { _, path in
            let client = try await connectedClient(path)
            let unknown = await #expect(throws: DaemonError.self) { try await client.call(PTYList.self, Empty()) }
            #expect(unknown?.code == .unknownMethod)
            let badParams = await #expect(throws: DaemonError.self) { try await client.call(MalformedPTYWrite.self, ["cols": 3]) }
            #expect(badParams?.code == .badParams)
            await #expect(throws: DaemonError(.noSuchPTY, "no pty p9")) { try await client.call(PTYClose.self, .init(ptyId: "p9")) }
            let other = await #expect(throws: DaemonError.self) {
                try await client.call(PTYResize.self, .init(ptyId: "p1", cols: 1, rows: 1))
            }
            #expect(other?.code == .internal)
            // None of those errors cost the connection.
            _ = try await client.call(PTYWrite.self, .init(ptyId: "p1", data: Data()))
            await client.close()
        }
    }

    @Test func concurrentCallsResolveToTheirOwnCallers() async throws {
        let handler = TestHandler()
        let gate = Gate()
        handler.router.on(Echo.self) { params, _ in
            try await Task.sleep(for: .milliseconds(params.delayMillis))
            return params.value
        }
        handler.router.on(SessionClose.self) { _, _ in
            await gate.wait()
            return Empty()
        }
        handler.router.on(PTYWrite.self) { _, _ in Empty() }

        try await withServer(handler) { _, path in
            let client = try await connectedClient(path)
            // A graceful session.close can take up to 15 s; it must not hold up anything else on the connection.
            let slow = Task { try await client.call(SessionClose.self, .init(sessionKey: "s1")) }
            _ = try await within("pty.write behind a slow session.close") {
                try await client.call(PTYWrite.self, .init(ptyId: "p1", data: Data("x".utf8)))
            }
            try await withThrowingTaskGroup(of: (Int, Int).self) { group in
                for value in 0 ..< 200 {
                    group.addTask { (value, try await client.call(Echo.self, .init(value: value, delayMillis: Int.random(in: 0 ... 25)))) }
                }
                for try await (sent, received) in group { #expect(sent == received) }
            }
            await gate.open()
            #expect(try await slow.value == Empty())
            await client.close()
        }
    }

    // MARK: - Pushes

    @Test(arguments: [1, 4])
    func pushesArriveInSendOrder(senders: Int) async throws {
        let handler = TestHandler()
        emitOutputRoute(handler)
        let total = 10_000
        try await withServer(handler) { _, path in
            let client = try await connectedClient(path)
            let pushes = client.pushes
            let collector = Task { () -> [PTYID: [Int]] in
                var seqs: [PTYID: [Int]] = [:]
                var count = 0
                for await frame in pushes {
                    guard case .ptyOutput(let output) = frame, let seq = Int(String(decoding: output.data, as: UTF8.self)) else { continue }
                    seqs[output.ptyId, default: []].append(seq)
                    count += 1
                    if count == total { break }
                }
                return seqs
            }
            // Senders run concurrently on the server (one request each); each must keep its own order.
            try await withThrowingTaskGroup(of: Void.self) { group in
                for sender in 0 ..< senders {
                    group.addTask { _ = try await client.call(EmitOutput.self, .init(ptyId: "p\(sender)", count: total / senders)) }
                }
                try await group.waitForAll()
            }
            let received = try await within("\(total) pushes") { await collector.value }
            #expect(received.count == senders)
            for sender in 0 ..< senders {
                #expect(received["p\(sender)"] == Array(1 ... total / senders))
            }
            await client.close()
        }
    }

    @Test func broadcastRacingAWelcomeArrivesRightAfterIt() async throws {
        let gateWelcomes = OSAllocatedUnfairLock(initialState: false)
        let (entered, enteredSink) = AsyncStream.makeStream(of: Void.self)
        let gate = Gate()
        let handler = TestHandler(welcome: {
            if gateWelcomes.withLock({ $0 }) {
                enteredSink.yield()
                await gate.wait()
            }
            return [manifestEntry("old")]
        })
        let update = ServerFrame.sessions(SessionList(sessions: [manifestEntry("old"), manifestEntry("new")]))

        try await withServer(handler) { server, path in
            let open = try await connectedClient(path)
            gateWelcomes.withLock { $0 = true }
            let late = try RawClient(path: path)
            try late.send(.hello(Hello(clientVersion: "raw-test", token: testToken)))
            try await within("sessionsForWelcome") {
                for await _ in entered { return }
            }
            server.broadcast(update)
            await gate.open()
            // On the wire: the welcome (built before the change) first, then the change.
            guard case .welcome(let welcome)? = try await late.next() else {
                Issue.record("expected the welcome first")
                return
            }
            #expect(welcome.sessions == [manifestEntry("old")])
            #expect(try await late.next() == update)
            #expect(try await nextPush(open) == update)
            await open.close()
        }
    }

    // MARK: - Backpressure

    @Test func slowConsumerIsCutOffWithoutBlockingTheDaemon() async throws {
        let handler = TestHandler()
        let floods = floodRoute(handler)
        let frames = 64, bytesPerFrame = 256 * 1024
        try await withServer(handler, maxBacklogBytes: 1 << 20) { _, path in
            let raw = try RawClient(path: path)
            _ = try await raw.handshake()
            try raw.send(.request(Request(id: "1", method: Flood.name, params: ["frames": .number(Double(frames)), "bytesPerFrame": .number(Double(bytesPerFrame))])))
            // The client never reads while the daemon floods it.
            let elapsed = try await within("the flood loop") {
                for await duration in floods { return duration }
                throw TimedOut(what: "the flood loop (stream ended)")
            }
            #expect(elapsed < .seconds(5), "send must not block on a client that stopped reading")
            try await handler.waitForClosed()
            let received = try await raw.readToEOF()
            #expect(received < frames * bytesPerFrame / 8, "queued frames are dropped, not delivered: got \(received) bytes")
        }
    }

    @Test func pacedProducerNeverTripsTheCutoff() async throws {
        let handler = TestHandler()
        _ = floodRoute(handler)
        let frames = 48, bytesPerFrame = 64 * 1024
        try await withServer(handler, maxBacklogBytes: 512 * 1024) { _, path in
            let raw = try RawClient(path: path)
            _ = try await raw.handshake()
            try raw.send(.request(Request(id: "1", method: Flood.name, params: [
                "frames": .number(Double(frames)), "bytesPerFrame": .number(Double(bytesPerFrame)), "pacedAtMost": .number(128 * 1024),
            ])))
            var outputs = 0
            reading: while let frame = try await raw.next() {
                switch frame {
                case .ptyOutput(let output):
                    #expect(output.data.count == bytesPerFrame)
                    outputs += 1
                    try await Task.sleep(for: .milliseconds(1))
                case .response(let response):
                    #expect(response.ok)
                    break reading
                default:
                    Issue.record("unexpected \(frame)")
                }
            }
            #expect(outputs == frames)
        }
    }

    // MARK: - Shutdown

    @Test func stoppingTheServerEndsPushesAndPendingCalls() async throws {
        let handler = TestHandler()
        let gate = Gate()
        let (started, startedSink) = AsyncStream.makeStream(of: Void.self)
        handler.router.on(SessionClose.self) { _, _ in
            startedSink.yield()
            await gate.wait()
            return Empty()
        }
        let path = tempSocketPath()
        let server = IDEServer(socketPath: path, token: testToken, daemonVersion: "ompd-test", startedAt: testStartedAt, handler: handler)
        try await server.start()
        let client = try await connectedClient(path)
        let pushes = client.pushes
        let drained = Task { for await _ in pushes {} }
        let pending = Task { try await client.call(SessionClose.self, .init(sessionKey: "s1")) }
        try await within("the request to reach the handler") {
            for await _ in started { return }
        }

        await server.stop()
        try await within("pushes to finish") { await drained.value }
        await #expect(throws: IDETransportError.connectionClosed) { try await pending.value }

        // connectionClosed waits for the in-flight handler to return.
        try await Task.sleep(for: .milliseconds(300))
        #expect(await handler.closed.values.isEmpty)
        await gate.open()
        try await handler.waitForClosed()
    }
}

/// Leaves a socket file behind with nobody listening, like a daemon that died without cleaning up.
private func bindAndAbandon(_ path: String) throws {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw posixError() }
    defer { Darwin.close(fd) }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path.utf8) }
    let result = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard result == 0 else { throw posixError() }
}
