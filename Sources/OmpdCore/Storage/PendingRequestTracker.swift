import Foundation
import IDEProtocol

/// Mirror of the requests an omp process is blocked on, i.e. its pending `extension_ui_request` dialogs and
/// `host_tool_call`s, kept as verbatim frames so they can be re-presented after a reconnect
/// (`SessionManifestEntry.pending`) or reported as abandoned when omp dies.
///
/// `extension_ui_request` methods (omp 18.3 `rpc-mode`):
/// - `select`, `confirm`, `input`, `editor`: omp waits for an `extension_ui_response`; tracked. Tool approvals are
///   plain `select`s. `select`/`confirm`/`input` may carry `timeout` (ms), after which omp silently resolves the
///   dialog to its default without telling the host — see `expire(now:)`.
/// - `cancel`: omp withdrew the dialog `targetId` (aborted); it no longer takes an answer.
/// - `notify`, `setStatus`, `setWidget`, `setTitle`, `set_editor_text`, `open_url`: fire-and-forget; not tracked.
///
/// A `host_tool_call` is pending until the host sends its `host_tool_result` or omp withdraws it with
/// `host_tool_cancel {targetId}`.
public struct PendingRequestTracker: Sendable {
    public private(set) var pending: PendingRequests
    /// When omp resolves each timed dialog on its own, by request id.
    private var deadlines: [String: Date] = [:]

    private static let dialogMethods: Set<String> = ["select", "confirm", "input", "editor"]

    /// Restored timed dialogs are assumed to have been received at `restoredAt`: their true receipt time is not
    /// persisted, so they expire no earlier than omp resolved them.
    public init(restoring: PendingRequests = .init(), restoredAt: Date = Date()) {
        pending = restoring
        for request in restoring.uiRequests {
            if let id = request["id"]?.stringValue, let deadline = Self.deadline(of: request, receivedAt: restoredAt) {
                deadlines[id] = deadline
            }
        }
    }

    /// Feed every omp stdout frame; `receivedAt` starts the clock of a dialog's `timeout`. Tracks dialogs that
    /// await a response and `host_tool_call`s, and drops them on `cancel` / `host_tool_cancel`.
    /// Returns true if `pending` changed.
    public mutating func observe(ompFrame frame: JSONValue, receivedAt: Date = Date()) -> Bool {
        switch frame["type"]?.stringValue {
        case "extension_ui_request":
            guard let id = frame["id"]?.stringValue, let method = frame["method"]?.stringValue else { return false }
            if method == "cancel" {
                guard let target = frame["targetId"]?.stringValue else { return false }
                return removeUIRequest(id: target) != nil
            }
            guard Self.dialogMethods.contains(method), Self.index(of: id, in: pending.uiRequests) == nil else {
                return false
            }
            pending.uiRequests.append(frame)
            deadlines[id] = Self.deadline(of: frame, receivedAt: receivedAt)
            return true
        case "host_tool_call":
            guard let id = frame["id"]?.stringValue, Self.index(of: id, in: pending.hostToolCalls) == nil else {
                return false
            }
            pending.hostToolCalls.append(frame)
            return true
        case "host_tool_cancel":
            guard let target = frame["targetId"]?.stringValue,
                let index = Self.index(of: target, in: pending.hostToolCalls)
            else { return false }
            pending.hostToolCalls.remove(at: index)
            return true
        default:
            return false
        }
    }

    /// Feed every frame the daemon writes to omp's stdin. An `extension_ui_response` answers its dialog; a
    /// `host_tool_result` completes its call only if omp would accept it (`result.content` is an array — omp
    /// rejects anything else and keeps waiting). Returns true if `pending` changed.
    public mutating func observe(sentToOmp frame: JSONValue) -> Bool {
        guard let id = frame["id"]?.stringValue else { return false }
        switch frame["type"]?.stringValue {
        case "extension_ui_response":
            return removeUIRequest(id: id) != nil
        case "host_tool_result":
            guard frame["result"]?["content"]?.arrayValue != nil,
                let index = Self.index(of: id, in: pending.hostToolCalls)
            else { return false }
            pending.hostToolCalls.remove(at: index)
            return true
        default:
            return false
        }
    }

    /// Earliest moment a timed dialog lapses; schedule `expire(now:)` for then. nil when none is pending.
    public var nextDeadline: Date? { deadlines.values.min() }

    /// Drops dialogs whose `timeout` has elapsed by `now` — omp already resolved them to their default and ignores
    /// late answers, so they must not be re-presented. Returns the dropped request frames, earliest deadline first.
    @discardableResult
    public mutating func expire(now: Date) -> [JSONValue] {
        let lapsed = deadlines.filter { $0.value <= now }.sorted { $0.value < $1.value }
        return lapsed.compactMap { removeUIRequest(id: $0.key) }
    }

    /// omp died: every pending request is abandoned. Returns them and starts over empty.
    public mutating func clear() -> PendingRequests {
        let abandoned = pending
        pending = PendingRequests()
        deadlines.removeAll()
        return abandoned
    }

    private mutating func removeUIRequest(id: String) -> JSONValue? {
        deadlines[id] = nil
        guard let index = Self.index(of: id, in: pending.uiRequests) else { return nil }
        return pending.uiRequests.remove(at: index)
    }

    private static func index(of id: String, in frames: [JSONValue]) -> Int? {
        frames.firstIndex { $0["id"]?.stringValue == id }
    }

    private static func deadline(of request: JSONValue, receivedAt: Date) -> Date? {
        guard let milliseconds = request["timeout"]?.doubleValue, milliseconds > 0 else { return nil }
        return receivedAt.addingTimeInterval(milliseconds / 1000)
    }
}
