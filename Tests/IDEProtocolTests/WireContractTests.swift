import Foundation
@testable import IDEProtocol
import Testing

private let t0 = Date(timeIntervalSince1970: 1_790_330_000.25)

private func encode(_ value: some Encodable) throws -> String {
    String(decoding: try IDECoding.encoder().encode(value), as: UTF8.self)
}

private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try IDECoding.decoder().decode(T.self, from: Data(json.utf8))
}

/// The frame as the peer sees it on the wire, and decoded back.
private func wire<T: Codable & Equatable>(_ value: T) throws -> (json: JSONValue, decoded: T) {
    let data = try IDECoding.encoder().encode(value)
    return (try JSONDecoder().decode(JSONValue.self, from: data), try IDECoding.decoder().decode(T.self, from: data))
}

private func entry(_ key: SessionKey) -> SessionManifestEntry {
    SessionManifestEntry(
        sessionKey: key, workspace: "/Users/me/src/app", sessionFile: "/Users/me/.omp/s.jsonl", sessionId: "sid", title: "Fix it",
        launch: LaunchSpec(ompPath: "/opt/homebrew/bin/omp", ompVersion: "18.3.1", approvalMode: "always-ask", model: "anthropic/claude-haiku-4-5"),
        status: .busy, lastSeq: 42, lastSettledAt: t0, createdAt: t0,
        services: [NamedService(id: "web", mode: "session", command: "bun dev", ready: ["port": 3000])],
        pending: PendingRequests(
            uiRequests: [HeldRequest(frame: ["type": "extension_ui_request", "id": "7", "method": "select", "options": ["Approve", "Deny"]], receivedAt: t0)],
            hostToolCalls: [HeldRequest(frame: ["type": "host_tool_call", "id": "h1", "toolName": "echo_host"], receivedAt: t0)]))
}

@Suite struct ClientFrameContractTests {
    @Test func helloIsTheExactWireShape() throws {
        let hello = ClientFrame.hello(Hello(protocolVersion: 2, clientVersion: "0.1 (7)", token: "abc"))
        #expect(try encode(hello) == #"{"clientVersion":"0.1 (7)","protocolVersion":2,"token":"abc","type":"hello"}"#)
        #expect(try wire(hello).decoded == hello)
    }

    @Test func requestIsTheExactWireShape() throws {
        let request = ClientFrame.request(Request(id: "9", method: UIRespond.name, params: ["requestId": "r1", "response": ["value": "Approve"]]))
        #expect(try encode(request) == #"{"id":"9","method":"ui.respond","params":{"requestId":"r1","response":{"value":"Approve"}},"type":"request"}"#)
        #expect(try wire(request).decoded == request)
    }

    @Test func anUnknownOrMissingTypeIsRejected() {
        #expect(throws: DecodingError.self) { try decode(ClientFrame.self, #"{"type":"subscribe","id":"1"}"#) }
        #expect(throws: DecodingError.self) { try decode(ClientFrame.self, #"{"id":"1","method":"x","params":null}"#) }
    }
}

@Suite struct ServerFrameContractTests {
    static let frames: [(type: String, frame: ServerFrame)] = [
        ("welcome", .welcome(Welcome(daemonVersion: "0.1.0", daemonStartedAt: t0, sessions: [entry("s1")]))),
        ("response", .response(Response(id: "1", result: ["replayedThrough": 12]))),
        ("response", .response(Response(id: "2", error: DaemonError(.readOnly, "ompd is read-only")))),
        ("event", .event(JournalRecord(sessionKey: "s1", seq: 3, ts: t0, kind: .omp, payload: ["type": "agent_start"]))),
        ("resync", .resync(Resync(sessionKey: "s1", lastSeq: 40))),
        ("pty_output", .ptyOutput(PTYOutput(ptyId: "p1", data: Data([0x1B, 0x5B, 0x48, 0x00, 0xFF])))),
        ("sessions", .sessions(SessionList(sessions: [entry("s1"), entry("s2")]))),
        ("notice", .notice(DaemonNotice(level: "error", message: "ompd is read-only", at: t0))),
        ("notice", .notice(DaemonNotice(level: "warning", message: "omp exited", sessionKey: "s1", at: t0))),
    ]

    @Test(arguments: frames.indices)
    func everyFrameRoundTripsWithItsWireType(_ index: Int) throws {
        let (type, frame) = Self.frames[index]
        let (json, decoded) = try wire(frame)
        #expect(json["type"] == .string(type))
        #expect(decoded == frame)
    }

    @Test func payloadFieldsSitNextToTheTypeDiscriminator() throws {
        #expect(try encode(ServerFrame.resync(Resync(sessionKey: "s1", lastSeq: 40))) == #"{"lastSeq":40,"sessionKey":"s1","type":"resync"}"#)
        #expect(try encode(ServerFrame.response(Response(id: "2", error: DaemonError(.versionMismatch, "v1 client")))) ==
            #"{"error":{"code":"version_mismatch","message":"v1 client"},"id":"2","ok":false,"type":"response"}"#)
        #expect(try encode(ServerFrame.ptyOutput(PTYOutput(ptyId: "p1", data: Data("hi".utf8)))) == #"{"data":"aGk=","ptyId":"p1","type":"pty_output"}"#)
        #expect(try encode(ServerFrame.event(JournalRecord(sessionKey: "s1", seq: 3, ts: t0, kind: .stderr, payload: ["text": "x"]))) ==
            #"{"kind":"stderr","payload":{"text":"x"},"seq":3,"sessionKey":"s1","ts":"2026-09-25T09:53:20.250","type":"event"}"#)
        #expect(try encode(ServerFrame.notice(DaemonNotice(level: "info", message: "m", sessionKey: "s1", at: t0))) ==
            #"{"at":"2026-09-25T09:53:20.250","level":"info","message":"m","sessionKey":"s1","type":"notice"}"#)
    }

    @Test func aDaemonWideNoticeHasNoSessionKey() throws {
        let notice = try decode(ServerFrame.self, #"{"type":"notice","level":"error","message":"read-only","at":"2026-09-25T09:53:20.250Z"}"#)
        #expect(notice == .notice(DaemonNotice(level: "error", message: "read-only", sessionKey: nil, at: t0)))
    }

    @Test func anUnknownTypeIsRejected() {
        #expect(throws: DecodingError.self) { try decode(ServerFrame.self, #"{"type":"telemetry","x":1}"#) }
    }
}

@Suite struct DaemonEventContractTests {
    static let events: [DaemonEvent] = [
        .spawned(pid: 4242, ompVersion: "18.3.1", resumed: true),
        .exited(code: 0, signal: nil, sessionExitKind: "normal"),
        .exited(code: nil, signal: 9, sessionExitKind: nil),
        .statusChanged(.needsAttention),
        .lost(fromSeq: 26, toSeq: 67, reason: "omp was killed"),
        .uiAnswered(requestId: "r1", response: ["value": "Approve"]),
        .uiAnswered(requestId: "h1", response: ["result": ["content": [["type": "text", "text": "done"]]]]),
        .uiAbandoned(requestId: "r2"),
        .notice(level: "warning", message: "bridge did not connect"),
    ]

    @Test(arguments: events)
    func everyEventRoundTrips(_ event: DaemonEvent) throws {
        #expect(try wire(event).decoded == event)
        // Journal payloads go through `JSONValue` (the reducer's path).
        #expect(try JSONValue(encoding: event).decode(DaemonEvent.self) == event)
    }

    @Test func journaledShapesStayReadable() throws {
        let lines: [(String, DaemonEvent)] = [
            (#"{"spawned":{"ompVersion":"18.3.1","pid":4242,"resumed":false}}"#, .spawned(pid: 4242, ompVersion: "18.3.1", resumed: false)),
            (#"{"exited":{"signal":9}}"#, .exited(code: nil, signal: 9, sessionExitKind: nil)),
            (#"{"statusChanged":{"_0":"needs_attention"}}"#, .statusChanged(.needsAttention)),
            (#"{"lost":{"fromSeq":26,"reason":"r","toSeq":67}}"#, .lost(fromSeq: 26, toSeq: 67, reason: "r")),
            (#"{"uiAbandoned":{"requestId":"r2"}}"#, .uiAbandoned(requestId: "r2")),
            (#"{"notice":{"level":"info","message":"m"}}"#, .notice(level: "info", message: "m")),
            (#"{"uiAnswered":{"requestId":"r1","response":{"confirmed":false}}}"#, .uiAnswered(requestId: "r1", response: ["confirmed": false])),
        ]
        for (json, event) in lines {
            #expect(try decode(DaemonEvent.self, json) == event, "\(json)")
            #expect(try encode(event) == json, "encoding is unchanged")
        }
    }

    @Test func aProtocol1AnswerDecodesWithANullResponse() throws {
        #expect(try decode(DaemonEvent.self, #"{"uiAnswered":{"requestId":"158d569562c98aeb"}}"#) ==
            .uiAnswered(requestId: "158d569562c98aeb", response: .null))
    }

    @Test func malformedEventsAreRejected() {
        #expect(throws: DecodingError.self) { try decode(DaemonEvent.self, #"{"rebooted":{}}"#) }
        #expect(throws: DecodingError.self) { try decode(DaemonEvent.self, #"{"uiAbandoned":{"requestId":"a"},"notice":{"level":"i","message":"m"}}"#) }
        #expect(throws: DecodingError.self) { try decode(DaemonEvent.self, #"{"uiAnswered":{"response":{"value":"x"}}}"#) }
    }
}

@Suite struct ManifestContractTests {
    @Test func heldRequestsKeepTheirArrivalTime() throws {
        let pending = entry("s1").pending
        let (json, decoded) = try wire(pending)
        #expect(json["uiRequests"]?.arrayValue?.first?["receivedAt"] == "2026-09-25T09:53:20.250")
        #expect(json["uiRequests"]?.arrayValue?.first?["frame"]?["id"] == "7")
        #expect(decoded == pending)
    }

    @Test func protocol1BareFramesArriveNow() throws {
        let before = Date()
        let pending = try decode(PendingRequests.self, #"""
            {"uiRequests":[{"type":"extension_ui_request","id":"7","method":"input","timeout":60000}],
             "hostToolCalls":[{"type":"host_tool_call","id":"h1","toolName":"echo_host"}]}
            """#)
        let after = Date()
        #expect(pending.uiRequests.map(\.frame) == [["type": "extension_ui_request", "id": "7", "method": "input", "timeout": 60000]])
        #expect(pending.hostToolCalls.map(\.id) == ["h1"])
        for request in pending.uiRequests + pending.hostToolCalls {
            #expect(request.receivedAt >= before && request.receivedAt <= after)
        }
    }

    @Test func aFrameThatMerelyHasAFrameKeyIsStillAFrame() throws {
        let request = try decode(HeldRequest.self, #"{"type":"extension_ui_request","id":"x","frame":"not a wrapper"}"#)
        #expect(request.frame == ["type": "extension_ui_request", "id": "x", "frame": "not a wrapper"])
    }

    @Test func namedServiceDefaultsMissingFields() throws {
        let service = try decode(NamedService.self, #"{"id":"web","mode":"detached"}"#)
        #expect(service == NamedService(id: "web", mode: "detached", command: nil, cwd: nil, env: [:], pty: true, ready: nil, desiredRunning: true))
        #expect(throws: DecodingError.self) { try decode(NamedService.self, #"{"id":"web"}"#) }
    }

    @Test func aWholeEntryRoundTrips() throws {
        let original = entry("s1")
        #expect(try wire(original).decoded == original)
    }
}

@Suite struct IDECodingDateTests {
    @Test(arguments: [0.0, 0.25, 0.0004, 0.0005, 0.0015, 0.9994, 0.9996, 0.123456789])
    func encodeDecodeIsAFixedPointAfterOneTrip(_ fraction: Double) throws {
        let date = Date(timeIntervalSince1970: 1_790_330_000 + fraction)
        let first = try IDECoding.encoder().encode([date])
        let once = try IDECoding.decoder().decode([Date].self, from: first)
        let second = try IDECoding.encoder().encode(once)
        #expect(second == first, "re-encoding a decoded date gives the same bytes")
        #expect(try IDECoding.decoder().decode([Date].self, from: second) == once)
        #expect(abs(once[0].timeIntervalSince(date)) <= 0.0005 + 1e-6, "within half a millisecond")
    }

    /// Dates go out as UTC wall time with milliseconds and no zone designator; `Z`-suffixed input (hand-written
    /// fixtures, other tools) reads the same.
    @Test func millisecondDatesAreExact() throws {
        #expect(try encode([t0]) == #"["2026-09-25T09:53:20.250"]"#)
        #expect(try decode([Date].self, #"["2026-09-25T09:53:20.250"]"#) == [t0])
        #expect(try decode([Date].self, #"["2026-09-25T09:53:20.250Z"]"#) == [t0])
    }

    @Test func acceptsDatesWithoutFractionAndRejectsGarbage() throws {
        #expect(try decode([Date].self, #"["2026-09-25T09:53:20Z"]"#) == [Date(timeIntervalSince1970: 1_790_330_000)])
        #expect(throws: DecodingError.self) { try decode([Date].self, #"["yesterday"]"#) }
    }
}
