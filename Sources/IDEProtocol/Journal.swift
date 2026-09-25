import Foundation

/// One line of `$APP_SUPPORT/journal/<sessionKey>.jsonl` and, identically, one `ServerFrame.event`.
public struct JournalRecord: Sendable, Equatable, Codable {
    public var sessionKey: SessionKey
    public var seq: Seq
    public var ts: Date
    public var kind: Kind
    /// For `.omp`: the verbatim omp stdout frame (after v2 chunk reassembly). For `.daemon`: a `DaemonEvent`
    /// encoded as JSON. For `.stderr`: `{"text": "..."}`. For `.compacted`: `{"ompEntryId": "...", "fromSeq": n, "toSeq": m}`.
    public var payload: JSONValue

    public enum Kind: String, Sendable, Codable {
        case omp
        case daemon
        case stderr
        /// Deltas collapsed after `session_settled`. Points at the durable omp entry.
        case compacted
        /// ide-bridge push (agent registry change, async-job snapshot, …): the complete agent tree incl.
        /// idle/parked/aborted rows that RPC `get_subagents` never reports.
        case bridge
    }

    public init(sessionKey: SessionKey, seq: Seq, ts: Date, kind: Kind, payload: JSONValue) {
        self.sessionKey = sessionKey
        self.seq = seq
        self.ts = ts
        self.kind = kind
        self.payload = payload
    }
}

/// Daemon-originated lifecycle facts, journaled with kind `.daemon`.
public enum DaemonEvent: Sendable, Equatable, Codable {
    /// omp child spawned. `resumed` = launched with `--resume`.
    case spawned(pid: Int32, ompVersion: String, resumed: Bool)
    /// omp child exited. `signal` set when killed by a signal.
    case exited(code: Int32?, signal: Int32?, sessionExitKind: String?)
    case statusChanged(SessionStatus)
    /// Journal seqs `fromSeq...toSeq` were never persisted by omp before it died.
    case lost(fromSeq: Seq, toSeq: Seq, reason: String)
    /// A UI request (`extension_ui_request` / `host_tool_call`) was answered by a client. `response` is the answer the
    /// daemon forwarded to omp (the `ui.respond` payload, minus `type`/`id`); `.null` in journals written before
    /// protocol 2, which recorded only that an answer was sent.
    case uiAnswered(requestId: String, response: JSONValue)
    /// A pending UI request can no longer be answered (omp died). Rendered as aborted, never defaulted.
    case uiAbandoned(requestId: String)
    case notice(level: String, message: String)

    // Encoding is synthesized (`{"<case>": {<labels>}}`); decoding is spelled out to accept journals written before
    // `uiAnswered` carried its `response`.
    private enum CodingKeys: String, CodingKey { case spawned, exited, statusChanged, lost, uiAnswered, uiAbandoned, notice }
    private enum SpawnedCodingKeys: String, CodingKey { case pid, ompVersion, resumed }
    private enum ExitedCodingKeys: String, CodingKey { case code, signal, sessionExitKind }
    private enum StatusChangedCodingKeys: String, CodingKey { case _0 }
    private enum LostCodingKeys: String, CodingKey { case fromSeq, toSeq, reason }
    private enum UiAnsweredCodingKeys: String, CodingKey { case requestId, response }
    private enum UiAbandonedCodingKeys: String, CodingKey { case requestId }
    private enum NoticeCodingKeys: String, CodingKey { case level, message }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.allKeys.count == 1, let key = container.allKeys.first else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: container.codingPath, debugDescription: "a DaemonEvent has exactly one known case key"))
        }
        switch key {
        case .spawned:
            let c = try container.nestedContainer(keyedBy: SpawnedCodingKeys.self, forKey: key)
            self = .spawned(
                pid: try c.decode(Int32.self, forKey: .pid), ompVersion: try c.decode(String.self, forKey: .ompVersion),
                resumed: try c.decode(Bool.self, forKey: .resumed))
        case .exited:
            let c = try container.nestedContainer(keyedBy: ExitedCodingKeys.self, forKey: key)
            self = .exited(
                code: try c.decodeIfPresent(Int32.self, forKey: .code), signal: try c.decodeIfPresent(Int32.self, forKey: .signal),
                sessionExitKind: try c.decodeIfPresent(String.self, forKey: .sessionExitKind))
        case .statusChanged:
            let c = try container.nestedContainer(keyedBy: StatusChangedCodingKeys.self, forKey: key)
            self = .statusChanged(try c.decode(SessionStatus.self, forKey: ._0))
        case .lost:
            let c = try container.nestedContainer(keyedBy: LostCodingKeys.self, forKey: key)
            self = .lost(
                fromSeq: try c.decode(Seq.self, forKey: .fromSeq), toSeq: try c.decode(Seq.self, forKey: .toSeq),
                reason: try c.decode(String.self, forKey: .reason))
        case .uiAnswered:
            let c = try container.nestedContainer(keyedBy: UiAnsweredCodingKeys.self, forKey: key)
            self = .uiAnswered(
                requestId: try c.decode(String.self, forKey: .requestId),
                response: try c.decodeIfPresent(JSONValue.self, forKey: .response) ?? .null)
        case .uiAbandoned:
            let c = try container.nestedContainer(keyedBy: UiAbandonedCodingKeys.self, forKey: key)
            self = .uiAbandoned(requestId: try c.decode(String.self, forKey: .requestId))
        case .notice:
            let c = try container.nestedContainer(keyedBy: NoticeCodingKeys.self, forKey: key)
            self = .notice(level: try c.decode(String.self, forKey: .level), message: try c.decode(String.self, forKey: .message))
        }
    }
}
