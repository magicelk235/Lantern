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
        status: .busy, ptyId: "p-\(key)", createdAt: t0, lastActiveAt: t0,
        services: [NamedService(id: "web", mode: "session", command: "bun dev", ready: ["port": 3000])])
}

private let sessionPTY = PTYInfo(
    ptyId: "p-s1", cwd: "/Users/me/src/app", command: ["/opt/homebrew/bin/omp", "--resume", "/Users/me/.omp/s.jsonl"],
    cols: 120, rows: 40, pid: 4242, running: true, sessionKey: "s1")
private let terminal = PTYInfo(ptyId: "t1", cwd: "/Users/me", command: ["/bin/zsh", "-l"], cols: 80, rows: 24, pid: nil, running: false)

@Suite struct ClientFrameContractTests {
    @Test func helloIsTheExactWireShape() throws {
        let hello = ClientFrame.hello(Hello(protocolVersion: 2, clientVersion: "0.1 (7)", token: "abc"))
        #expect(try encode(hello) == #"{"clientKind":"app","clientVersion":"0.1 (7)","hasWindow":true,"protocolVersion":2,"token":"abc","type":"hello"}"#)
        #expect(try wire(hello).decoded == hello)
        let cli = ClientFrame.hello(Hello(clientVersion: "ompd-cli", token: "abc", clientKind: .cli))
        #expect(try wire(cli).json["clientKind"] == "cli")
        #expect(try wire(cli).decoded == cli)
    }

    /// Only Lantern windows keep the sessions running; a client that does not say what it is, or whether it has a
    /// window, counts as an app with one (apps from before the fields).
    @Test func aHelloWithoutAClientKindIsAnAppWindow() throws {
        let frame = try decode(ClientFrame.self, #"{"type":"hello","protocolVersion":4,"clientVersion":"0.1","token":"abc"}"#)
        #expect(frame == .hello(Hello(protocolVersion: 4, clientVersion: "0.1", token: "abc", clientKind: .app, hasWindow: true)))
        let windowless = try decode(ClientFrame.self, #"{"type":"hello","protocolVersion":4,"clientVersion":"0.1","token":"abc","hasWindow":false}"#)
        #expect(windowless == .hello(Hello(protocolVersion: 4, clientVersion: "0.1", token: "abc", hasWindow: false)))
        #expect(throws: DecodingError.self) {
            try decode(ClientFrame.self, #"{"type":"hello","protocolVersion":4,"clientVersion":"0.1","token":"abc","clientKind":"robot"}"#)
        }
    }

    @Test func requestIsTheExactWireShape() throws {
        let request = ClientFrame.request(Request(id: "9", method: PTYAttach.name, params: ["ptyId": "p-s1"]))
        #expect(try encode(request) == #"{"id":"9","method":"pty.attach","params":{"ptyId":"p-s1"},"type":"request"}"#)
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
        ("response", .response(Response(id: "1", result: ["ptyId": "p1"]))),
        ("response", .response(Response(id: "2", error: DaemonError(.bridgeUnavailable, "no ide-bridge")))),
        ("pty_output", .ptyOutput(PTYOutput(ptyId: "p1", data: Data([0x1B, 0x5B, 0x48, 0x00, 0xFF])))),
        ("sessions", .sessions(SessionList(sessions: [entry("s1"), entry("s2")]))),
        ("notice", .notice(DaemonNotice(level: "error", message: "ompd is read-only", at: t0))),
        ("notice", .notice(DaemonNotice(level: "warning", message: "omp exited", sessionKey: "s1", at: t0))),
        ("ptys", .ptys(PTYList.Result(ptys: [sessionPTY, terminal]))),
    ]

    @Test(arguments: frames.indices)
    func everyFrameRoundTripsWithItsWireType(_ index: Int) throws {
        let (type, frame) = Self.frames[index]
        let (json, decoded) = try wire(frame)
        #expect(json["type"] == .string(type))
        #expect(decoded == frame)
    }

    @Test func payloadFieldsSitNextToTheTypeDiscriminator() throws {
        #expect(try encode(ServerFrame.response(Response(id: "2", error: DaemonError(.versionMismatch, "v1 client")))) ==
            #"{"error":{"code":"version_mismatch","message":"v1 client"},"id":"2","ok":false,"type":"response"}"#)
        #expect(try encode(ServerFrame.ptyOutput(PTYOutput(ptyId: "p1", data: Data("hi".utf8)))) == #"{"data":"aGk=","ptyId":"p1","type":"pty_output"}"#)
        #expect(try encode(ServerFrame.notice(DaemonNotice(level: "info", message: "m", sessionKey: "s1", at: t0))) ==
            #"{"at":"2026-09-25T09:53:20.250","level":"info","message":"m","sessionKey":"s1","type":"notice"}"#)
        #expect(try encode(ServerFrame.ptys(PTYList.Result(ptys: [terminal]))) ==
            #"{"ptys":[{"cols":80,"command":["/bin/zsh","-l"],"cwd":"/Users/me","ptyId":"t1","rows":24,"running":false}],"type":"ptys"}"#)
    }

    /// Clients tell session TUIs from terminals by `sessionKey`: present on session PTYs, absent on terminals.
    @Test func sessionPTYsCarryTheirSessionKeyAndTerminalsDoNot() throws {
        let (json, _) = try wire(ServerFrame.ptys(PTYList.Result(ptys: [sessionPTY, terminal])))
        let ptys = try #require(json["ptys"]?.arrayValue)
        #expect(ptys[0]["sessionKey"] == "s1")
        #expect(ptys[1]["sessionKey"] == nil)
        #expect(try decode(PTYInfo.self, #"{"ptyId":"t1","cwd":"/","command":["sh"],"cols":80,"rows":24,"running":true}"#).sessionKey == nil)
    }

    @Test func aDaemonWideNoticeHasNoSessionKey() throws {
        let notice = try decode(ServerFrame.self, #"{"type":"notice","level":"error","message":"read-only","at":"2026-09-25T09:53:20.250Z"}"#)
        #expect(notice == .notice(DaemonNotice(level: "error", message: "read-only", sessionKey: nil, at: t0)))
    }

    @Test func anUnknownTypeIsRejected() {
        #expect(throws: DecodingError.self) { try decode(ServerFrame.self, #"{"type":"telemetry","x":1}"#) }
    }
}

@Suite struct SessionMethodContractTests {
    @Test func createAndOpenCarryTheInitialTUISize() throws {
        let create = SessionCreate.Params(workspace: "/w", approvalMode: "yolo", cols: 132, rows: 43)
        #expect(try encode(create) == #"{"approvalMode":"yolo","cols":132,"rows":43,"workspace":"/w"}"#)
        let open = SessionOpen.Params(sessionFile: "/s.jsonl", workspace: "/w", cols: 100, rows: 30)
        #expect(try encode(open) == #"{"cols":100,"rows":30,"sessionFile":"/s.jsonl","workspace":"/w"}"#)
        #expect(try wire(create).decoded == create)
        #expect(try wire(open).decoded == open)
    }

    @Test func statusesUseTheirWireNames() throws {
        let statuses: [SessionStatus] = [.starting, .busy, .idle, .interrupted, .resuming, .closed, .needsAttention, .paused]
        #expect(try encode(statuses) == #"["starting","busy","idle","interrupted","resuming","closed","needs_attention","paused"]"#)
    }
}

@Suite struct ManifestContractTests {
    @Test func runtimeFieldsAreOmittedWhenUnset() throws {
        var fresh = entry("s1")
        fresh.sessionFile = nil
        fresh.sessionId = nil
        fresh.title = nil
        fresh.ptyId = nil
        fresh.lastActiveAt = nil
        let (json, decoded) = try wire(fresh)
        for key in ["sessionFile", "sessionId", "title", "ptyId", "lastActiveAt"] {
            #expect(json[key] == nil, "\(key)")
        }
        #expect(decoded == fresh)
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
