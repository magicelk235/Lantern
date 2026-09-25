import Foundation
import IDEProtocol

/// How a prompt sent while the agent is busy joins the run (omp `prompt.streamingBehavior`, rpc.md).
public enum StreamingBehavior: String, Sendable, CaseIterable {
    /// Delivered at the next check between tool calls; may cut the remaining calls of the turn short.
    case steer
    /// Delivered once the current turn ends.
    case followUp
}

/// An answer to a held `Dialog` (omp `extension_ui_response` minus `type`/`id`).
public enum DialogResponse: Equatable, Sendable {
    /// `select` (any string; for an approval only `Approve` approves), `input`, `editor`.
    case value(String)
    /// `confirm`.
    case confirmed(Bool)
    /// Dismiss. Denies an approval; cancelling an `ask` aborts the whole run.
    case cancelled

    var json: JSONValue {
        switch self {
        case .value(let value): ["value": .string(value)]
        case .confirmed(let confirmed): ["confirmed": .bool(confirmed)]
        case .cancelled: ["cancelled": true]
        }
    }
}

/// omp `--approval-mode` for new sessions (approval-mode.md). nil everywhere means "use the omp configuration".
public enum ApprovalMode: String, Sendable, CaseIterable, Identifiable {
    case alwaysAsk = "always-ask"
    case write
    case yolo

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .alwaysAsk: "Always ask"
        case .write: "Ask before running commands"
        case .yolo: "Never ask"
        }
    }

    public var explanation: String {
        switch self {
        case .alwaysAsk: "Prompts before any tool that edits files or runs commands."
        case .write: "Edits apply without asking; commands and other exec tools prompt."
        case .yolo: "Every tool runs without asking."
        }
    }
}

/// omp RPC command objects sent through the daemon's `omp` passthrough (the daemon assigns `id`s).
enum OmpCommands {
    static func prompt(_ message: String, streamingBehavior: StreamingBehavior?) -> JSONValue {
        var command: [String: JSONValue] = ["type": "prompt", "message": .string(message)]
        if let streamingBehavior { command["streamingBehavior"] = .string(streamingBehavior.rawValue) }
        return .object(command)
    }

    static let abort: JSONValue = ["type": "abort"]
}
