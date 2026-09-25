import Foundation
@_exported import IDEProtocol

/// One row of a session transcript, folded from journal records (or a snapshot) by `TranscriptReducer`.
public struct TranscriptItem: Identifiable, Equatable, Sendable {
    /// Unique within one transcript. Items are only ever appended, so an id keeps its row for the transcript's life.
    public let id: String
    public var content: Content
    /// Seqs of the first and last journal record that added content to this item; nil when rebuilt from a snapshot.
    public internal(set) var seqs: ClosedRange<Seq>?
    /// Built from journal records omp never persisted before it died (`DaemonEvent.lost`): still shown (faded) but
    /// not part of the model's context.
    public internal(set) var isLost = false

    public enum Content: Equatable, Sendable {
        case user(UserMessage)
        case assistant(AssistantMessage)
        case tool(ToolCall)
        case dialog(Dialog)
        case notice(Notice)
    }

    init(id: String, content: Content, seq: Seq?) {
        self.id = id
        self.content = content
        seqs = seq.map { $0 ... $0 }
    }

    /// Records that `seq` added content to this item.
    mutating func touch(_ seq: Seq?) {
        guard let seq else { return }
        seqs = (seqs?.lowerBound ?? seq) ... seq
    }
}

public struct UserMessage: Equatable, Sendable {
    public var text: String
    public var imageCount: Int

    public init(text: String, imageCount: Int = 0) {
        self.text = text
        self.imageCount = imageCount
    }
}

public struct AssistantMessage: Equatable, Sendable {
    public struct Block: Equatable, Sendable {
        public enum Kind: Equatable, Sendable { case text, thinking }
        public var kind: Kind
        public var text: String

        public init(kind: Kind, text: String) {
            self.kind = kind
            self.text = text
        }
    }

    /// Text and thinking blocks in omp content order. Tool calls become their own `ToolCall` items.
    public var blocks: [Block]
    public var isStreaming: Bool
    /// omp `stopReason` once the message ended: `stop`, `toolUse`, `aborted`, `error`, ...
    public var stopReason: String?
    public var errorMessage: String?
    public var model: String?
    /// omp exited while this message was still streaming.
    public var wasInterrupted: Bool

    public init(
        blocks: [Block] = [], isStreaming: Bool, stopReason: String? = nil, errorMessage: String? = nil,
        model: String? = nil, wasInterrupted: Bool = false
    ) {
        self.blocks = blocks
        self.isStreaming = isStreaming
        self.stopReason = stopReason
        self.errorMessage = errorMessage
        self.model = model
        self.wasInterrupted = wasInterrupted
    }

    /// Nothing to show: no text, no thinking, no error (e.g. a turn that only called tools).
    public var isEmpty: Bool {
        !isStreaming && errorMessage == nil && blocks.allSatisfy { $0.text.isEmpty }
    }
}

public struct ToolCall: Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        /// The model is still streaming the call's arguments.
        case composing
        /// Fully formed; waiting to run (approval, queue).
        case pending
        case running
        case succeeded
        case failed
        /// omp exited before the call finished.
        case interrupted

        public var isFinished: Bool { rank >= Self.succeeded.rank }

        /// Lifecycle order; a status never moves backwards.
        var rank: Int {
            switch self {
            case .composing: 0
            case .pending: 1
            case .running: 2
            case .succeeded, .failed, .interrupted: 3
            }
        }
    }

    public var toolCallId: String
    public var name: String
    /// One-line digest of the arguments (the command, path, question, ... or compact JSON).
    public var summary: String
    /// The call's stated intent (omp's `intent` / the `i` argument).
    public var intent: String?
    public var status: Status
    /// Tail of the latest partial or final result text, at most `outputLimit` characters.
    public var output: String
    public var outputIsTruncated: Bool

    public static let outputLimit = 8_000

    public init(
        toolCallId: String, name: String, summary: String = "", intent: String? = nil, status: Status,
        output: String = "", outputIsTruncated: Bool = false
    ) {
        self.toolCallId = toolCallId
        self.name = name
        self.summary = summary
        self.intent = intent
        self.status = status
        self.output = output
        self.outputIsTruncated = outputIsTruncated
    }
}

/// An `extension_ui_request` omp is blocked on (`select`, `confirm`, `input`, `editor`), answered with `ui.respond`.
public struct Dialog: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable { case select, confirm, input, editor }

    public enum State: Equatable, Sendable {
        case pending
        /// A client answered it (daemon `uiAnswered`).
        case answered
        /// omp withdrew it (`cancel` with this `targetId`), e.g. after `abort` during an `ask`.
        case withdrawn
        /// Its `timeout` elapsed: omp resolved it to the default and ignores late answers.
        case expired
        /// omp died before it was answered (daemon `uiAbandoned` / `exited`). Never defaulted.
        case abandoned
    }

    public struct Option: Equatable, Sendable {
        public var label: String
        public var description: String?

        public init(label: String, description: String? = nil) {
            self.label = label
            self.description = description
        }
    }

    /// A tool approval: a `select` titled `Allow tool: <name>` whose options are exactly `Approve`/`Deny`.
    /// Only the value `Approve` approves.
    public struct Approval: Equatable, Sendable {
        public var toolName: String
        /// The title lines after the first: `Command: …`, `Path: …`, `Reason: …`.
        public var details: [String]

        public static let approve = "Approve"
        public static let deny = "Deny"
    }

    public var requestId: String
    public var kind: Kind
    public var title: String
    public var message: String?
    public var options: [Option]
    public var placeholder: String?
    public var prefill: String?
    /// When omp resolves the dialog on its own (`timeout` after the request arrived).
    public var expiresAt: Date?
    public var state: State
    public var approval: Approval?

    public var isPending: Bool { state == .pending }

    /// Parses an awaiting `extension_ui_request` frame; nil for any other method.
    public init?(request frame: JSONValue, receivedAt: Date?) {
        guard let requestId = frame["id"]?.stringValue,
              let kind = frame["method"]?.stringValue.flatMap(Kind.init(rawValue:))
        else { return nil }
        self.requestId = requestId
        self.kind = kind
        title = frame["title"]?.stringValue ?? ""
        message = frame["message"]?.stringValue
        let labels: [JSONValue] = frame["options"]?.arrayValue ?? []
        let details: [JSONValue] = frame["optionDetails"]?.arrayValue ?? []
        options = labels.enumerated().compactMap { index, label in
            guard let label = label.stringValue else { return nil }
            let description = details.indices.contains(index) ? details[index]["description"]?.stringValue : nil
            return Option(label: label, description: description)
        }
        placeholder = frame["placeholder"]?.stringValue
        prefill = frame["prefill"]?.stringValue
        if let receivedAt, let timeout = frame["timeout"]?.doubleValue, timeout > 0 {
            expiresAt = receivedAt.addingTimeInterval(timeout / 1000)
        } else {
            expiresAt = nil
        }
        state = .pending
        approval = Self.approval(kind: kind, title: title, options: options)
    }

    private static let approvalPrefix = "Allow tool: "

    private static func approval(kind: Kind, title: String, options: [Option]) -> Approval? {
        guard kind == .select, title.hasPrefix(approvalPrefix),
              options.map(\.label) == [Approval.approve, Approval.deny]
        else { return nil }
        var lines = title.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let toolName = String(lines.removeFirst().dropFirst(approvalPrefix.count))
        return Approval(toolName: toolName, details: lines)
    }
}

public struct Notice: Equatable, Sendable {
    public enum Level: String, Equatable, Sendable {
        case info, warning, error

        init(_ name: String?) {
            switch name?.lowercased() {
            case "warning", "warn": self = .warning
            case "error", "fatal": self = .error
            default: self = .info
            }
        }
    }

    public enum Kind: Equatable, Sendable {
        /// How a prompt ended (aborted, failed).
        case outcome
        case retry
        case compaction
        /// omp process lifecycle (spawned, exited).
        case process
        /// Journal seqs omp never persisted before it died; the affected items are marked `isLost`.
        case lost(fromSeq: Seq, toSeq: Seq)
        /// omp's stderr; consecutive lines accumulate in one notice.
        case stderr
        /// `notify` from an extension, or an `extension_error`.
        case extensionMessage
        /// Omp `notice` events and daemon notices.
        case message
    }

    public var kind: Kind
    public var level: Level
    public var text: String

    public init(kind: Kind, level: Level, text: String) {
        self.kind = kind
        self.level = level
        self.text = text
    }
}

extension TranscriptItem.Content {
    /// Mutates an assistant payload in place. The payload is moved out of `self` first so its buffers stay uniquely
    /// referenced; `if case var` would copy the whole message text on every streamed delta.
    mutating func withAssistant(_ body: (inout AssistantMessage) -> Void) {
        guard case .assistant(var message) = self else { return }
        self = .user(UserMessage(text: ""))
        body(&message)
        self = .assistant(message)
    }

    mutating func withTool(_ body: (inout ToolCall) -> Void) {
        guard case .tool(var tool) = self else { return }
        body(&tool)
        self = .tool(tool)
    }

    mutating func withDialog(_ body: (inout Dialog) -> Void) {
        guard case .dialog(var dialog) = self else { return }
        body(&dialog)
        self = .dialog(dialog)
    }

    mutating func withNotice(_ body: (inout Notice) -> Void) {
        guard case .notice(var notice) = self else { return }
        self = .user(UserMessage(text: ""))
        body(&notice)
        self = .notice(notice)
    }
}
