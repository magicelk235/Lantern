import Foundation
@_exported import OmpRPC

/// Daemon <-> UI protocol version. Bump on any incompatible change to this module.
public let ideProtocolVersion = 1

/// Wire framing: each frame is a 4-byte big-endian length followed by that many bytes of
/// UTF-8 JSON encoding exactly one `ClientFrame` or `ServerFrame`. Max frame 64 MiB.
public let ideMaxFrameBytes = 64 * 1024 * 1024

/// Opaque, stable identifier the daemon assigns to one omp session it owns. Survives omp respawns,
/// daemon restarts and reboots (persisted in `sessions.json`). Never an omp PID or sessionId.
public typealias SessionKey = String

/// Monotonic per-session journal sequence number, starting at 1. 0 means "nothing seen yet".
public typealias Seq = UInt64

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
    public init(protocolVersion: Int = ideProtocolVersion, clientVersion: String, token: String) {
        self.protocolVersion = protocolVersion
        self.clientVersion = clientVersion
        self.token = token
    }
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
    /// One journal record pushed to a subscriber (replayed or live; identical shape).
    case event(JournalRecord)
    /// The requested `since` is unknown (compacted/foreign); client must drop its view of the session and
    /// rebuild from `session.snapshot` before applying further events.
    case resync(Resync)
    /// Raw PTY output for an attached terminal.
    case ptyOutput(PTYOutput)
    /// Manifest changed (session created/closed/status change). Full list, cheap.
    case sessions(SessionList)

    private enum CodingKeys: String, CodingKey { case type }
    private enum Kind: String, Codable { case welcome, response, event, resync, ptyOutput = "pty_output", sessions }

    public init(from decoder: any Decoder) throws {
        let kind = try decoder.container(keyedBy: CodingKeys.self).decode(Kind.self, forKey: .type)
        switch kind {
        case .welcome: self = .welcome(try Welcome(from: decoder))
        case .response: self = .response(try Response(from: decoder))
        case .event: self = .event(try JournalRecord(from: decoder))
        case .resync: self = .resync(try Resync(from: decoder))
        case .ptyOutput: self = .ptyOutput(try PTYOutput(from: decoder))
        case .sessions: self = .sessions(try SessionList(from: decoder))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .welcome(let v): try c.encode(Kind.welcome, forKey: .type); try v.encode(to: encoder)
        case .response(let v): try c.encode(Kind.response, forKey: .type); try v.encode(to: encoder)
        case .event(let v): try c.encode(Kind.event, forKey: .type); try v.encode(to: encoder)
        case .resync(let v): try c.encode(Kind.resync, forKey: .type); try v.encode(to: encoder)
        case .ptyOutput(let v): try c.encode(Kind.ptyOutput, forKey: .type); try v.encode(to: encoder)
        case .sessions(let v): try c.encode(Kind.sessions, forKey: .type); try v.encode(to: encoder)
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
        case ompError = "omp_error", readOnly = "read_only", `internal`
    }
    public var code: Code
    public var message: String
    public init(_ code: Code, _ message: String) { self.code = code; self.message = message }
}

public struct Resync: Sendable, Equatable, Codable {
    public var sessionKey: SessionKey
    /// Seq the client should resume from after rebuilding via `session.snapshot`.
    public var lastSeq: Seq
    public init(sessionKey: SessionKey, lastSeq: Seq) { self.sessionKey = sessionKey; self.lastSeq = lastSeq }
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

/// Shared coders: ISO-8601 dates with fractional seconds, sorted keys (deterministic journal bytes).
public enum IDECoding {
    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .custom { date, enc in
            var c = enc.singleValueContainer()
            try c.encode(date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true)))
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
