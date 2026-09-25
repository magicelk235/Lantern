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
    /// A UI request (`extension_ui_request` / `host_tool_call`) was answered by a client.
    case uiAnswered(requestId: String)
    /// A pending UI request can no longer be answered (omp died). Rendered as aborted, never defaulted.
    case uiAbandoned(requestId: String)
    case notice(level: String, message: String)
}
