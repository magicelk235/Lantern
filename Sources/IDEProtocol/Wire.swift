import Foundation

/// Daemon <-> UI protocol version. Bump on any incompatible change to this module (5: `ServerFrame.runtime`, which a
/// v4 client cannot decode; agent supervision methods).
public let ideProtocolVersion = 5

/// Wire framing: each frame is a 4-byte big-endian length followed by that many bytes of
/// UTF-8 JSON encoding exactly one `ClientFrame` or `ServerFrame`. Max frame 64 MiB.
public let ideMaxFrameBytes = 64 * 1024 * 1024

/// Opaque, stable identifier the daemon assigns to one omp session it owns. Survives omp respawns,
/// daemon restarts and reboots (persisted in `sessions.json`). Never an omp PID or sessionId.
public typealias SessionKey = String


// MARK: - Client -> daemon

public enum ClientFrame: Sendable, Equatable, Codable {
    /// First frame on every connection. Anything else before a successful `welcome` closes the socket.
    case hello(Hello)
    case request(Request)

    private enum CodingKeys: String, CodingKey { case type }
    private enum Kind: String, Codable { case hello, request }

    public init(from decoder: any Decoder) throws {
        let kind = try decoder.container(keyedBy: CodingKeys.self).decode(Kind.self, forKey: .type)
        switch kind {
        case .hello: self = .hello(try Hello(from: decoder))
        case .request: self = .request(try Request(from: decoder))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .hello(let v): try c.encode(Kind.hello, forKey: .type); try v.encode(to: encoder)
        case .request(let v): try c.encode(Kind.request, forKey: .type); try v.encode(to: encoder)
        }
    }
}

public struct Hello: Sendable, Equatable, Codable {
    public var protocolVersion: Int
    public var clientVersion: String
    /// Contents of `$APP_SUPPORT/run/token` (0600).
    public var token: String
    /// What connects. Only an `app` with a window open keeps the sessions running.
    public var clientKind: ClientKind
    /// An `app` client has an omp IDE window open. ompd pauses every session while no connected app has one; the app
    /// reports changes through `ClientPresence`. A hello without it has one (apps before the field).
    public var hasWindow: Bool

    public init(
        protocolVersion: Int = ideProtocolVersion, clientVersion: String, token: String, clientKind: ClientKind = .app,
        hasWindow: Bool = true
    ) {
        self.protocolVersion = protocolVersion
        self.clientVersion = clientVersion
        self.token = token
        self.clientKind = clientKind
        self.hasWindow = hasWindow
    }

    private enum CodingKeys: String, CodingKey { case protocolVersion, clientVersion, token, clientKind, hasWindow }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try c.decode(Int.self, forKey: .protocolVersion)
        clientVersion = try c.decode(String.self, forKey: .clientVersion)
        token = try c.decode(String.self, forKey: .token)
        clientKind = try c.decodeIfPresent(ClientKind.self, forKey: .clientKind) ?? .app
        hasWindow = try c.decodeIfPresent(Bool.self, forKey: .hasWindow) ?? true
    }
}

public enum ClientKind: String, Sendable, Codable {
    /// An omp IDE window (the app). A hello without `clientKind` is one.
    case app
    /// A client that is no omp IDE window, such as `ompd status` or the menu-bar extra: it neither keeps the
    /// sessions running nor resumes them.
    case cli
}

/// JSON-RPC style request. `method` is a `DaemonMethod.name`; `params` its encoded `Params`.
public struct Request: Sendable, Equatable, Codable {
    public var id: String
    public var method: String
    public var params: JSONValue
    public init(id: String, method: String, params: JSONValue) {
        self.id = id
        self.method = method
        self.params = params
    }
}

// MARK: - Daemon -> client

public enum ServerFrame: Sendable, Equatable, Codable {
    case welcome(Welcome)
    case response(Response)
    /// Raw PTY output for an attached terminal.
    case ptyOutput(PTYOutput)
    /// Manifest changed (session created/closed/status change). Full list, cheap.
    case sessions(SessionList)
    /// Daemon notice (e.g. read-only mode, a session that could not be resumed). Broadcast to every connected
    /// client; not replayed to clients that connect later.
    case notice(DaemonNotice)
    /// The PTY list changed (opened, exited, closed, resized). Full list, cheap; replaces client polling.
    case ptys(PTYList.Result)
    /// One session's runtime changed (agents, jobs, what waits for the user). Sent for every change, and once with
    /// empty lists when its omp stops; clients fetch the whole set with `SessionRuntimeList` after connecting.
    case runtime(SessionRuntime)

    private enum CodingKeys: String, CodingKey { case type }
    private enum Kind: String, Codable { case welcome, response, ptyOutput = "pty_output", sessions, notice, ptys, runtime }

    public init(from decoder: any Decoder) throws {
        let kind = try decoder.container(keyedBy: CodingKeys.self).decode(Kind.self, forKey: .type)
        switch kind {
        case .welcome: self = .welcome(try Welcome(from: decoder))
        case .response: self = .response(try Response(from: decoder))
        case .ptyOutput: self = .ptyOutput(try PTYOutput(from: decoder))
        case .sessions: self = .sessions(try SessionList(from: decoder))
        case .notice: self = .notice(try DaemonNotice(from: decoder))
        case .ptys: self = .ptys(try PTYList.Result(from: decoder))
        case .runtime: self = .runtime(try SessionRuntime(from: decoder))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .welcome(let v): try c.encode(Kind.welcome, forKey: .type); try v.encode(to: encoder)
        case .response(let v): try c.encode(Kind.response, forKey: .type); try v.encode(to: encoder)
        case .ptyOutput(let v): try c.encode(Kind.ptyOutput, forKey: .type); try v.encode(to: encoder)
        case .sessions(let v): try c.encode(Kind.sessions, forKey: .type); try v.encode(to: encoder)
        case .notice(let v): try c.encode(Kind.notice, forKey: .type); try v.encode(to: encoder)
        case .ptys(let v): try c.encode(Kind.ptys, forKey: .type); try v.encode(to: encoder)
        case .runtime(let v): try c.encode(Kind.runtime, forKey: .type); try v.encode(to: encoder)
        }
    }
}

public struct Welcome: Sendable, Equatable, Codable {
    public var protocolVersion: Int
    public var daemonVersion: String
    /// Daemon process start time; changes when ompd restarted (client uses it to detect Regime B2).
    public var daemonStartedAt: Date
    public var sessions: [SessionManifestEntry]
    public init(protocolVersion: Int = ideProtocolVersion, daemonVersion: String, daemonStartedAt: Date, sessions: [SessionManifestEntry]) {
        self.protocolVersion = protocolVersion
        self.daemonVersion = daemonVersion
        self.daemonStartedAt = daemonStartedAt
        self.sessions = sessions
    }
}

public struct Response: Sendable, Equatable, Codable {
    public var id: String
    public var ok: Bool
    public var result: JSONValue?
    public var error: DaemonError?
    public init(id: String, result: JSONValue) { self.id = id; ok = true; self.result = result; error = nil }
    public init(id: String, error: DaemonError) { self.id = id; ok = false; result = nil; self.error = error }
}

public struct DaemonError: Error, Sendable, Equatable, Codable {
    public enum Code: String, Sendable, Codable {
        case unauthorized, versionMismatch = "version_mismatch", unknownMethod = "unknown_method", badParams = "bad_params"
        case noSuchSession = "no_such_session", noSuchPTY = "no_such_pty", sessionBusy = "session_busy"
        case ompError = "omp_error", readOnly = "read_only", bridgeUnavailable = "bridge_unavailable", `internal`
    }
    public var code: Code
    public var message: String
    public init(_ code: Code, _ message: String) { self.code = code; self.message = message }
}

public typealias PTYID = String

public struct PTYOutput: Sendable, Equatable, Codable {
    public var ptyId: PTYID
    public var data: Data // base64 on the wire (JSONEncoder default)
    public init(ptyId: PTYID, data: Data) { self.ptyId = ptyId; self.data = data }
}

public struct SessionList: Sendable, Equatable, Codable {
    public var sessions: [SessionManifestEntry]
    public init(sessions: [SessionManifestEntry]) { self.sessions = sessions }
}

/// A daemon-wide or per-session notice (`ServerFrame.notice`).
public struct DaemonNotice: Sendable, Equatable, Codable {
    /// `info` | `warning` | `error`.
    public var level: String
    public var message: String
    /// The session it concerns; nil for daemon-wide notices.
    public var sessionKey: SessionKey?
    public var at: Date
    /// What the notice is about, for clients that offer an action on it (`DaemonNotice.diskSpaceTopic`); nil for most
    /// notices, and from older ompds.
    public var topic: String?
    public init(level: String, message: String, sessionKey: SessionKey? = nil, at: Date, topic: String? = nil) {
        self.level = level
        self.message = message
        self.sessionKey = sessionKey
        self.at = at
        self.topic = topic
    }
}

/// Shared coders: ISO-8601 dates with fractional seconds, sorted keys (deterministic bytes).
public enum IDECoding {
    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .custom { date, enc in
            var c = enc.singleValueContainer()
            // FormatStyle truncates to ms; bias by half a ms so encode∘decode is a fixed point (byte-stable replay).
            try c.encode(date.addingTimeInterval(0.0005).formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true)))
        }
        return e
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let s = try dec.singleValueContainer().decode(String.self)
            if let date = try? Date(s, strategy: .iso8601.year().month().day().time(includingFractionalSeconds: true)) { return date }
            if let date = try? Date(s, strategy: .iso8601) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: dec.codingPath, debugDescription: "bad date \(s)"))
        }
        return d
    }
}
