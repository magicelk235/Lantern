import Darwin
import Foundation
import IDEProtocol
import Testing
@testable import OmpdCore

@Suite struct BridgeServerTests {
    /// A bridge whose handshake the server accepted.
    private func connected(_ server: BridgeServer, key: SessionKey = "s1") async throws -> FakeBridge {
        let credentials = await server.expect(sessionKey: key)
        await server.setExpectedPID(getpid(), for: key)
        let bridge = try FakeBridge(socketPath: server.socketPath)
        #expect(try await bridge.handshake(credentials)?["t"] == "welcome")
        _ = try await server.waitForHello(key, timeout: .seconds(5))
        return bridge
    }

    @Test func wrongTokenIsRejectedAndTheRealBridgeStillGetsIn() async throws {
        try await withBridgeServer { server in
            let credentials = await server.expect(sessionKey: "s1")
            await server.setExpectedPID(getpid(), for: "s1")

            let impostor = try FakeBridge(socketPath: server.socketPath)
            try impostor.sendHello(sessionKey: "s1", token: String(repeating: "0", count: 64))
            let verdict = try await impostor.next()
            #expect(verdict?["t"] == "reject")
            #expect(verdict?["reason"]?.stringValue?.contains("token") == true)
            #expect(try await impostor.next() == nil)
            await #expect(throws: BridgeError.unauthorized) { try await server.waitForHello("s1", timeout: .milliseconds(200)) }

            let bridge = try FakeBridge(socketPath: server.socketPath)
            #expect(try await bridge.handshake(credentials)?["t"] == "welcome")
            let hello = try await server.waitForHello("s1", timeout: .seconds(5))
            #expect(hello.sessionKey == "s1")
            #expect(hello.pid == getpid())
            #expect(hello.ompVersion == "18.3.1")
            #expect(hello.capabilities == ["session.ensureOnDisk": true, "agent.revive": false])
            #expect(hello.sessionFile == "/tmp/omb-session.jsonl")
            #expect(hello.onDisk == false)
            #expect(hello.artifactsDir == "/tmp/omb-session")
            #expect(hello.raw["token"] == nil)

            // The token is spent: a second hello with it is refused, the first connection keeps working.
            let replay = try FakeBridge(socketPath: server.socketPath)
            #expect(try await replay.handshake(credentials)?["t"] == "reject")
        }
    }

    @Test func peerThatIsNotTheSpawnedProcessIsRejected() async throws {
        try await withBridgeServer { server in
            let credentials = await server.expect(sessionKey: "s1")
            await server.setExpectedPID(1, for: "s1") // launchd: never this test process

            let bridge = try FakeBridge(socketPath: server.socketPath)
            let verdict = try await bridge.handshake(credentials)
            #expect(verdict?["t"] == "reject")
            #expect(verdict?["reason"]?.stringValue?.contains("pid") == true)
            await #expect(throws: BridgeError.unauthorized) { try await server.waitForHello("s1", timeout: .milliseconds(200)) }

            // A hello claiming the expected pid is checked against the kernel's view of the peer.
            let liar = try FakeBridge(socketPath: server.socketPath)
            try liar.sendHello(sessionKey: "s1", token: credentials.token, pid: 1)
            #expect(try await liar.next()?["t"] == "reject")
        }
    }

    @Test func helloBeforeThePIDIsKnownIsHeldUntilSetExpectedPID() async throws {
        try await withBridgeServer { server in
            let credentials = await server.expect(sessionKey: "s1")
            let bridge = try FakeBridge(socketPath: server.socketPath)
            try bridge.sendHello(sessionKey: "s1", token: credentials.token)
            let waiting = Task { try await server.waitForHello("s1", timeout: .seconds(5)) }
            try await Task.sleep(for: .milliseconds(200))
            await server.setExpectedPID(getpid(), for: "s1")
            #expect(try await bridge.next()?["t"] == "welcome")
            #expect(try await waiting.value.pid == getpid())
        }
    }

    @Test func waitingForAHelloThatNeverComesTimesOut() async throws {
        try await withBridgeServer { server in
            _ = await server.expect(sessionKey: "s1")
            await #expect(throws: BridgeError.helloTimeout) { try await server.waitForHello("s1", timeout: .milliseconds(100)) }
            await #expect(throws: BridgeError.notConnected) { try await server.waitForHello("unknown", timeout: .seconds(5)) }
            await #expect(throws: BridgeError.notConnected) { try await server.call("s1", method: "session.info") }
        }
    }

    @Test func concurrentCallsAreCorrelatedByID() async throws {
        try await withBridgeServer { server in
            let bridge = try await connected(server)
            let count = 16
            let results = Task {
                try await withThrowingTaskGroup(of: (Int, JSONValue).self) { group in
                    for n in 0..<count {
                        group.addTask { (n, try await server.call("s1", method: "test.times10", params: ["n": .number(Double(n))])) }
                    }
                    var all: [Int: JSONValue] = [:]
                    for try await (n, result) in group { all[n] = result }
                    return all
                }
            }
            var requests: [JSONValue] = []
            for _ in 0..<count {
                let request = try #require(try await bridge.next())
                #expect(request["t"] == "req")
                #expect(request["method"] == "test.times10")
                requests.append(request)
            }
            for request in requests.reversed() {
                let n = try #require(request["params"]?["n"]?.intValue)
                try bridge.send(["t": "res", "id": request["id"]!, "ok": true, "result": ["n": .number(Double(n * 10))]])
            }
            let all = try await results.value
            #expect(all.count == count)
            for n in 0..<count { #expect(all[n] == ["n": .number(Double(n * 10))]) }
        }
    }

    @Test func failedAndUnansweredCalls() async throws {
        try await withBridgeServer { server in
            let bridge = try await connected(server)
            let failing = Task { try await server.call("s1", method: "agent.revive", params: ["id": "Ghost"]) }
            let request = try #require(try await bridge.next())
            try bridge.send(["t": "res", "id": request["id"]!, "ok": false, "error": "unknown agent: Ghost"])
            await #expect(throws: BridgeError.callFailed(method: "agent.revive", message: "unknown agent: Ghost")) {
                try await failing.value
            }
            await #expect(throws: BridgeError.callTimeout(method: "jobs.snapshot")) {
                try await server.call("s1", method: "jobs.snapshot", timeout: .milliseconds(100))
            }
            // A late answer to the timed-out call is ignored and the connection stays usable.
            let late = try #require(try await bridge.next())
            try bridge.send(["t": "res", "id": late["id"]!, "ok": true, "result": nil])
            let next = Task { try await server.call("s1", method: "session.info") }
            let info = try #require(try await bridge.next())
            try bridge.send(["t": "res", "id": info["id"]!, "ok": true, "result": ["id": "0199aaaa"]])
            #expect(try await next.value == ["id": "0199aaaa"])
        }
    }

    @Test func eventsAndGapsArriveVerbatimAndFinishWhenTheBridgeHangsUp() async throws {
        try await withBridgeServer { server in
            let bridge = try await connected(server)
            let sent: [JSONValue] = [
                ["t": "evt", "seq": 1, "ts": 1_790_000_000_000, "agentId": "Main", "kind": "session_start", "data": ["isMain": true]],
                ["t": "evt", "seq": 2, "ts": 1_790_000_000_001, "agentId": "Pinger", "kind": "registry:registered",
                 "data": ["id": "Pinger", "parentId": "Main", "status": "running"]],
                ["t": "gap", "ts": 1_790_000_000_002, "from": 3, "to": 5, "dropped": 3],
                ["t": "evt", "seq": 6, "ts": 1_790_000_000_003, "agentId": nil, "kind": "registry:removed", "data": nil],
            ]
            for frame in sent { try bridge.send(frame) }
            bridge.close()
            #expect(try await bridgeCollect(server.events("s1")) == sent)
        }
    }

    @Test func disconnectFailsCallsInFlight() async throws {
        try await withBridgeServer { server in
            let bridge = try await connected(server)
            let inFlight = Task { try await server.call("s1", method: "agent.message", params: ["id": "Pinger", "body": "hi"]) }
            #expect(try await bridge.next()?["method"] == "agent.message")
            bridge.close()
            await #expect(throws: BridgeError.disconnected) { try await inFlight.value }
            await #expect(throws: BridgeError.disconnected) { try await server.call("s1", method: "session.info") }
            #expect(try await bridgeCollect(server.events("s1")).isEmpty)
        }
    }

    @Test func forgetDropsTheConnectionAndFailsWaiters() async throws {
        try await withBridgeServer { server in
            let bridge = try await connected(server)
            let inFlight = Task { try await server.call("s1", method: "session.flush") }
            _ = try await bridge.next()
            let unanswered = await server.expect(sessionKey: "s2")
            let waiting = Task { try await server.waitForHello(unanswered.sessionKey, timeout: .seconds(5)) }
            try await Task.sleep(for: .milliseconds(50))

            await server.forget("s1")
            await server.forget("s2")
            await #expect(throws: BridgeError.disconnected) { try await inFlight.value }
            await #expect(throws: BridgeError.notConnected) { try await waiting.value }
            #expect(try await bridge.next() == nil)
            await #expect(throws: BridgeError.notConnected) { try await server.call("s1", method: "session.info") }
        }
    }

    @Test func socketFileLifecycle() async throws {
        let path = bridgeSocketPath()
        let server = BridgeServer(socketPath: path)
        try await server.start()
        var info = stat()
        #expect(lstat(path, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o600)

        let rival = BridgeServer(socketPath: path)
        await #expect(throws: BridgeError.addressInUse(path: path)) { try await rival.start() }

        await server.stop()
        #expect(lstat(path, &info) == -1 && errno == ENOENT)

        // A socket file nobody listens on (a crashed daemon's) is replaced.
        let stale = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = try BridgeSocket.address(path)
        _ = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(stale, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        Darwin.close(stale)
        let successor = BridgeServer(socketPath: path)
        try await successor.start()
        await successor.stop()

        let tooLong = BridgeServer(socketPath: "/tmp/" + String(repeating: "x", count: 120))
        await #expect(throws: BridgeError.self) { try await tooLong.start() }
    }
}
