import Foundation
import IDEProtocol

/// Folds one session's journal records into transcript items.
///
/// Deterministic: the state depends only on the records applied (plus the instants passed to `expireDialogs(asOf:)`).
/// Records at or below `lastSeq` are ignored, so a replay overlapping what was already applied changes nothing, and
/// replaying 1...N into a fresh reducer after a resync rebuilds exactly the same items. Items are only ever appended;
/// streaming deltas append to the open message's text in place.
public struct TranscriptReducer: Equatable, Sendable {
    public enum Activity: Equatable, Sendable {
        /// Settled: nothing runs and nothing can wake the agent.
        case idle
        /// Busy without streaming: between turns, background work pending, compaction.
        case working
        /// A run is streaming (`agent_start` ... `agent_end`).
        case streaming
    }

    public internal(set) var items: [TranscriptItem] = []
    /// Seq of the last record applied, or the snapshot's seq after `rebuild(from:)`.
    public internal(set) var lastSeq: Seq = 0
    public internal(set) var activity: Activity = .idle

    /// Messages between `message_start` and `message_end` by omp `messageId`. omp numbers messages per process, so
    /// this starts over whenever a new omp process spawns.
    var openMessages: [String: OpenMessage] = [:]
    /// Dialog items by omp request id (also per process).
    var dialogsByRequest: [String: Int] = [:]
    /// Tool items by `toolCallId` (provider ids: unique across processes).
    var toolsByCall: [String: Int] = [:]
    /// Item indices of dialogs still awaiting an answer.
    var pendingDialogItems: Set<Int> = []
    var unfinishedTools: Set<Int> = []
    /// The stderr notice further `.stderr` records extend while it is still the last item.
    var stderrNotice: Int?

    struct OpenMessage: Equatable, Sendable {
        /// Item the message renders into; nil for messages shown elsewhere (tool results) or not at all.
        var item: Int?
        /// omp `contentIndex` -> index in `AssistantMessage.blocks`.
        var blocks: [Int: Int] = [:]
    }

    /// Longest stderr tail one notice keeps.
    static let stderrLimit = 32_000

    public init() {}

    public mutating func apply(_ record: JournalRecord) {
        guard record.seq > lastSeq else { return }
        lastSeq = record.seq
        expireDialogs(asOf: record.ts)
        switch record.kind {
        case .omp:
            applyOmp(record.payload, seq: record.seq, at: record.ts)
        case .daemon:
            // An event this build does not know (newer daemon) is skipped instead of failing the whole replay.
            if let event = try? record.payload.decode(DaemonEvent.self) { applyDaemon(event, seq: record.seq) }
        case .stderr:
            appendStderr(record.payload["text"]?.stringValue ?? "", seq: record.seq)
        case .compacted:
            // The collapsed range is readable only through omp's entries (`SessionViewModel` resyncs when it had not
            // seen it); nothing up to its end is missing.
            if let toSeq = record.payload["toSeq"]?.seqValue { lastSeq = max(lastSeq, toSeq) }
        case .bridge:
            break // agent tree and jobs belong to their own panes
        }
    }

    /// Marks pending dialogs whose `timeout` has elapsed by `date` as expired: omp resolved them to their default
    /// without telling anyone.
    public mutating func expireDialogs(asOf date: Date) {
        let lapsed = pendingDialogItems.filter { index in
            guard case .dialog(let dialog) = items[index].content, let deadline = dialog.expiresAt else { return false }
            return deadline <= date
        }
        for index in lapsed {
            pendingDialogItems.remove(index)
            items[index].content.withDialog { $0.state = .expired }
        }
    }

    /// Earliest timeout among pending dialogs; call `expireDialogs(asOf:)` then.
    public var nextDialogDeadline: Date? {
        pendingDialogItems.compactMap { index -> Date? in
            guard case .dialog(let dialog) = items[index].content else { return nil }
            return dialog.expiresAt
        }.min()
    }

    /// Dialogs still awaiting an answer, oldest first.
    public var pendingDialogs: [Dialog] {
        pendingDialogItems.sorted().compactMap { index in
            guard case .dialog(let dialog) = items[index].content else { return nil }
            return dialog
        }
    }

    public var pendingDialogCount: Int { pendingDialogItems.count }

    // MARK: - omp frames

    private mutating func applyOmp(_ frame: JSONValue, seq: Seq, at date: Date) {
        switch frame["type"]?.stringValue {
        case "message_start":
            startMessage(frame, seq: seq)
        case "message_update":
            updateMessage(frame, seq: seq)
        case "message_end":
            endMessage(frame, seq: seq)
        case "tool_execution_start":
            guard let id = frame["toolCallId"]?.stringValue else { return }
            upsertTool(
                id, name: frame["toolName"]?.stringValue, arguments: frame["args"], intent: frame["intent"]?.stringValue,
                status: .running, seq: seq)
        case "tool_execution_update":
            guard let id = frame["toolCallId"]?.stringValue else { return }
            let index = upsertTool(id, name: frame["toolName"]?.stringValue, arguments: nil, intent: nil, status: .running, seq: seq)
            setOutput(of: index, OmpContent.toolOutput(frame["partialResult"]))
        case "tool_execution_end":
            guard let id = frame["toolCallId"]?.stringValue else { return }
            let status: ToolCall.Status = frame["isError"]?.boolValue == true ? .failed : .succeeded
            let index = upsertTool(id, name: frame["toolName"]?.stringValue, arguments: nil, intent: nil, status: status, seq: seq)
            setOutput(of: index, OmpContent.toolOutput(frame["result"]))
        case "extension_ui_request":
            uiRequest(frame, seq: seq, at: date)
        case "agent_start":
            activity = .streaming
        case "agent_end":
            if activity == .streaming { activity = .working }
        case "prompt_result":
            promptResult(frame, seq: seq)
        case "session_settled":
            activity = .idle
        default:
            if let notice = Self.notice(for: frame) { append(.notice(notice), id: "notice:\(seq)", seq: seq) }
        }
    }

    static func messageKey(_ frame: JSONValue, seq: Seq) -> String {
        frame["messageId"]?.stringValue ?? "seq:\(seq)"
    }

    private mutating func startMessage(_ frame: JSONValue, seq: Seq) {
        let key = Self.messageKey(frame, seq: seq)
        guard openMessages[key] == nil, let message = frame["message"] else { return }
        switch message["role"]?.stringValue {
        case "user":
            openMessages[key] = OpenMessage(item: append(.user(Self.userMessage(message)), id: "user:\(seq)", seq: seq))
        case "assistant":
            // The start frame already carries the first delta's text, and that delta follows as its own event: start
            // empty and let the deltas fill the blocks.
            let assistant = AssistantMessage(isStreaming: true, model: message["model"]?.stringValue)
            openMessages[key] = OpenMessage(item: append(.assistant(assistant), id: "assistant:\(seq)", seq: seq))
        default:
            openMessages[key] = OpenMessage(item: nil)
        }
    }

    private mutating func updateMessage(_ frame: JSONValue, seq: Seq) {
        guard let event = frame["assistantMessageEvent"] else { return }
        let key = Self.messageKey(frame, seq: seq)
        guard let open = openMessages[key] else {
            // Joined mid-stream (subscribed after a snapshot): `message` is the whole message so far, this event
            // included.
            seedAssistant(frame["message"], key: key, seq: seq)
            return
        }
        guard let index = open.item else { return }
        let contentIndex = event["contentIndex"]?.intValue ?? 0
        switch event["type"]?.stringValue {
        case "text_start":
            _ = block(contentIndex, .text, of: key, item: index)
        case "thinking_start":
            _ = block(contentIndex, .thinking, of: key, item: index)
        case "text_delta":
            appendDelta(event["delta"]?.stringValue, contentIndex, .text, of: key, item: index)
        case "thinking_delta":
            appendDelta(event["delta"]?.stringValue, contentIndex, .thinking, of: key, item: index)
        case "text_end":
            settleBlock(event["content"]?.stringValue, contentIndex, .text, of: key, item: index)
        case "thinking_end":
            settleBlock(event["content"]?.stringValue, contentIndex, .thinking, of: key, item: index)
        case "toolcall_start":
            if let call = frame["message"]?["content"]?.element(at: contentIndex) { upsertTool(block: call, status: .composing, seq: seq) }
        case "toolcall_end":
            if let call = event["toolCall"] { upsertTool(block: call, status: .pending, seq: seq) }
        default:
            return
        }
        items[index].touch(seq)
    }

    private mutating func endMessage(_ frame: JSONValue, seq: Seq) {
        guard let message = frame["message"] else { return }
        let key = Self.messageKey(frame, seq: seq)
        defer { openMessages[key] = nil }
        switch message["role"]?.stringValue {
        case "user":
            if openMessages[key] == nil { append(.user(Self.userMessage(message)), id: "user:\(seq)", seq: seq) }
        case "assistant":
            let index: Int
            if let open = openMessages[key]?.item {
                index = open
            } else {
                index = append(.assistant(AssistantMessage(isStreaming: true)), id: "assistant:\(seq)", seq: seq)
                openMessages[key] = OpenMessage(item: index)
            }
            absorb(message["content"], of: key, item: index, toolStatus: .pending, seq: seq)
            items[index].content.withAssistant { assistant in
                assistant.isStreaming = false
                assistant.stopReason = message["stopReason"]?.stringValue
                assistant.errorMessage = message["errorMessage"]?.stringValue
                assistant.model = message["model"]?.stringValue ?? assistant.model
            }
            items[index].touch(seq)
        case "toolResult":
            finishTool(result: message, seq: seq)
        default:
            break
        }
    }

    private mutating func seedAssistant(_ message: JSONValue?, key: String, seq: Seq) {
        guard let message, message["role"]?.stringValue == "assistant" else {
            openMessages[key] = OpenMessage(item: nil)
            return
        }
        let assistant = AssistantMessage(isStreaming: true, model: message["model"]?.stringValue)
        let index = append(.assistant(assistant), id: "assistant:\(seq)", seq: seq)
        openMessages[key] = OpenMessage(item: index)
        absorb(message["content"], of: key, item: index, toolStatus: .composing, seq: seq)
    }

    /// Makes the message's blocks match a full content array (final message, or a mid-stream partial).
    private mutating func absorb(_ content: JSONValue?, of key: String, item index: Int, toolStatus: ToolCall.Status, seq: Seq) {
        for (contentIndex, block) in (content?.arrayValue ?? []).enumerated() {
            switch block["type"]?.stringValue {
            case "text": settleBlock(block["text"]?.stringValue, contentIndex, .text, of: key, item: index)
            case "thinking": settleBlock(block["thinking"]?.stringValue, contentIndex, .thinking, of: key, item: index)
            case "toolCall": upsertTool(block: block, status: toolStatus, seq: seq)
            default: break
            }
        }
    }

    /// Index in the message's `blocks` for omp `contentIndex`, appending an empty block the first time.
    private mutating func block(_ contentIndex: Int, _ kind: AssistantMessage.Block.Kind, of key: String, item index: Int) -> Int {
        if let existing = openMessages[key]?.blocks[contentIndex] { return existing }
        var position = 0
        items[index].content.withAssistant { message in
            position = message.blocks.count
            message.blocks.append(AssistantMessage.Block(kind: kind, text: ""))
        }
        openMessages[key]?.blocks[contentIndex] = position
        return position
    }

    private mutating func appendDelta(
        _ delta: String?, _ contentIndex: Int, _ kind: AssistantMessage.Block.Kind, of key: String, item index: Int
    ) {
        guard let delta, !delta.isEmpty else { return }
        let position = block(contentIndex, kind, of: key, item: index)
        items[index].content.withAssistant { $0.blocks[position].text.append(delta) }
    }

    /// Replaces a block's text with the authoritative full text only if the deltas did not already produce it.
    private mutating func settleBlock(
        _ text: String?, _ contentIndex: Int, _ kind: AssistantMessage.Block.Kind, of key: String, item index: Int
    ) {
        guard let text, !text.isEmpty || openMessages[key]?.blocks[contentIndex] != nil else { return }
        let position = block(contentIndex, kind, of: key, item: index)
        items[index].content.withAssistant { message in
            if message.blocks[position].text != text { message.blocks[position].text = text }
        }
    }

    // MARK: - Tools

    @discardableResult
    mutating func upsertTool(block: JSONValue, status: ToolCall.Status, seq: Seq?) -> Int? {
        guard let id = block["id"]?.stringValue else { return nil }
        return upsertTool(id, name: block["name"]?.stringValue, arguments: block["arguments"], intent: nil, status: status, seq: seq)
    }

    @discardableResult
    mutating func upsertTool(
        _ id: String, name: String?, arguments: JSONValue?, intent: String?, status: ToolCall.Status, seq: Seq?
    ) -> Int {
        let intent = intent ?? arguments?["i"]?.stringValue
        guard let index = toolsByCall[id] else {
            let tool = ToolCall(
                toolCallId: id, name: name ?? "tool", summary: OmpContent.toolSummary(arguments), intent: intent, status: status)
            let index = append(.tool(tool), id: "tool:\(id)", seq: seq)
            toolsByCall[id] = index
            if !status.isFinished { unfinishedTools.insert(index) }
            return index
        }
        items[index].content.withTool { tool in
            if let name, !name.isEmpty { tool.name = name }
            if let arguments, !tool.status.isFinished { tool.summary = OmpContent.toolSummary(arguments) }
            if let intent, !intent.isEmpty { tool.intent = intent }
            if status.rank > tool.status.rank { tool.status = status }
        }
        if status.isFinished { unfinishedTools.remove(index) }
        items[index].touch(seq)
        return index
    }

    /// Completes a tool from its `toolResult` message unless `tool_execution_end` already did.
    mutating func finishTool(result message: JSONValue, seq: Seq?) {
        guard let id = message["toolCallId"]?.stringValue else { return }
        if let index = toolsByCall[id], case .tool(let tool) = items[index].content, tool.status.isFinished { return }
        let status: ToolCall.Status = message["isError"]?.boolValue == true ? .failed : .succeeded
        let index = upsertTool(id, name: message["toolName"]?.stringValue, arguments: nil, intent: nil, status: status, seq: seq)
        setOutput(of: index, OmpContent.toolOutput(message))
    }

    private mutating func setOutput(of index: Int, _ output: (text: String, truncated: Bool)) {
        items[index].content.withTool { tool in
            tool.output = output.text
            tool.outputIsTruncated = output.truncated
        }
    }

    // MARK: - Dialogs, outcomes, notices

    private mutating func uiRequest(_ frame: JSONValue, seq: Seq, at date: Date) {
        switch frame["method"]?.stringValue {
        case "select", "confirm", "input", "editor":
            if let dialog = Dialog(request: frame, receivedAt: date) { appendDialog(dialog, id: "dialog:\(seq)", seq: seq) }
        case "cancel":
            if let target = frame["targetId"]?.stringValue { resolveDialog(target, as: .withdrawn) }
        case "notify":
            let notice = Notice(
                kind: .extensionMessage, level: Notice.Level(frame["notifyType"]?.stringValue),
                text: frame["message"]?.stringValue ?? "")
            append(.notice(notice), id: "notice:\(seq)", seq: seq)
        default:
            break // setStatus, setWidget, setTitle, set_editor_text, open_url: not transcript content
        }
    }

    mutating func appendDialog(_ dialog: Dialog, id: String, seq: Seq?) {
        let index = append(.dialog(dialog), id: id, seq: seq)
        dialogsByRequest[dialog.requestId] = index
        pendingDialogItems.insert(index)
    }

    private mutating func resolveDialog(_ requestId: String, as state: Dialog.State) {
        guard let index = dialogsByRequest[requestId], pendingDialogItems.remove(index) != nil else { return }
        items[index].content.withDialog { $0.state = state }
    }

    private mutating func promptResult(_ frame: JSONValue, seq: Seq) {
        if frame["sessionSettled"]?.boolValue == true { activity = .idle }
        let notice: Notice
        switch frame["status"]?.stringValue {
        case "aborted":
            notice = Notice(kind: .outcome, level: .warning, text: "Stopped.")
        case "error":
            notice = Notice(kind: .outcome, level: .error, text: frame["error"]?["message"]?.stringValue ?? "The prompt failed.")
        default:
            return
        }
        append(.notice(notice), id: "notice:\(seq)", seq: seq)
    }

    static func notice(for frame: JSONValue) -> Notice? {
        switch frame["type"]?.stringValue {
        case "auto_retry_start":
            let attempt = frame["attempt"]?.intValue.map(String.init) ?? "?"
            let maximum = frame["maxAttempts"]?.intValue.map { "/\($0)" } ?? ""
            let delay = frame["delayMs"]?.doubleValue.map { String(format: " in %.1fs", $0 / 1000) } ?? ""
            let reason = frame["errorMessage"]?.stringValue.map { ": \($0)" } ?? ""
            return Notice(kind: .retry, level: .warning, text: "Retrying (attempt \(attempt)\(maximum))\(delay)\(reason)")
        case "auto_retry_end":
            if frame["success"]?.boolValue == true { return Notice(kind: .retry, level: .info, text: "Retry succeeded.") }
            let reason = frame["finalError"]?.stringValue.map { ": \($0)" } ?? "."
            return Notice(kind: .retry, level: .error, text: "Retries exhausted\(reason)")
        case "auto_compaction_start":
            let reason = frame["reason"]?.stringValue.map { " (\($0))" } ?? ""
            return Notice(kind: .compaction, level: .info, text: "Compacting context\(reason)…")
        case "auto_compaction_end":
            if let error = frame["errorMessage"]?.stringValue {
                return Notice(kind: .compaction, level: .error, text: "Compaction failed: \(error)")
            }
            if frame["aborted"]?.boolValue == true { return Notice(kind: .compaction, level: .warning, text: "Compaction aborted.") }
            if frame["skipped"]?.boolValue == true { return Notice(kind: .compaction, level: .info, text: "Compaction skipped.") }
            return Notice(kind: .compaction, level: .info, text: "Context compacted.")
        case "retry_fallback_applied":
            let target = frame["to"]?.stringValue ?? "a fallback model"
            let reason = frame["reason"]?.stringValue.map { ": \($0)" } ?? ""
            return Notice(kind: .retry, level: .warning, text: "Switched to \(target)\(reason)")
        case "notice":
            guard let message = frame["message"]?.stringValue else { return nil }
            return Notice(kind: .message, level: Notice.Level(frame["level"]?.stringValue), text: message)
        case "extension_error":
            let path = frame["extensionPath"]?.stringValue.map { URL(filePath: $0).lastPathComponent } ?? "extension"
            let event = frame["event"]?.stringValue.map { " (\($0))" } ?? ""
            return Notice(
                kind: .extensionMessage, level: .error,
                text: "\(path)\(event): \(frame["error"]?.stringValue ?? "unknown error")")
        default:
            return nil
        }
    }

    // MARK: - Daemon events

    private mutating func applyDaemon(_ event: DaemonEvent, seq: Seq) {
        switch event {
        case .spawned(let pid, let ompVersion, let resumed):
            interruptOpenWork()
            dialogsByRequest = [:]
            activity = .idle
            let what = resumed ? "resumed the session" : "started"
            append(.notice(Notice(kind: .process, level: .info, text: "omp \(ompVersion) \(what) (pid \(pid)).")), id: "notice:\(seq)", seq: seq)
        case .exited(let code, let signal, let sessionExitKind):
            interruptOpenWork()
            activity = .idle
            append(.notice(Self.exitNotice(code: code, signal: signal, sessionExitKind: sessionExitKind)), id: "notice:\(seq)", seq: seq)
        case .statusChanged(let status):
            switch status {
            case .busy: if activity == .idle { activity = .working }
            case .settled, .closed, .interrupted, .needsAttention: activity = .idle
            case .starting, .resuming: break
            }
        case .lost(let fromSeq, let toSeq, let reason):
            guard fromSeq <= toSeq else { return }
            let range = fromSeq ... toSeq
            for index in items.indices where items[index].seqs?.overlaps(range) == true {
                items[index].isLost = true
            }
            let text = "omp never saved the output above (\(reason)). It stays visible here but is not part of the model's context."
            append(.notice(Notice(kind: .lost(fromSeq: fromSeq, toSeq: toSeq), level: .warning, text: text)), id: "notice:\(seq)", seq: seq)
        case .uiAnswered(let requestId, let response):
            resolveDialog(requestId, as: .answered(DialogResponse(json: response)))
        case .uiAbandoned(let requestId):
            resolveDialog(requestId, as: .abandoned)
        case .notice(let level, let message):
            append(.notice(Notice(kind: .message, level: Notice.Level(level), text: message)), id: "notice:\(seq)", seq: seq)
        }
    }

    /// The omp process is gone: nothing still open can finish.
    mutating func interruptOpenWork() {
        for open in openMessages.values {
            guard let index = open.item else { continue }
            items[index].content.withAssistant { message in
                guard message.isStreaming else { return }
                message.isStreaming = false
                message.wasInterrupted = true
            }
        }
        openMessages = [:]
        for index in unfinishedTools {
            items[index].content.withTool { $0.status = .interrupted }
        }
        unfinishedTools = []
        for index in pendingDialogItems {
            items[index].content.withDialog { $0.state = .abandoned }
        }
        pendingDialogItems = []
    }

    private static let signalNames: [Int32: String] = [1: "SIGHUP", 2: "SIGINT", 6: "SIGABRT", 9: "SIGKILL", 11: "SIGSEGV", 15: "SIGTERM"]

    static func exitNotice(code: Int32?, signal: Int32?, sessionExitKind: String?) -> Notice {
        let detail = sessionExitKind.map { " (session exit: \($0))" } ?? ""
        if let signal {
            let name = signalNames[signal].map { "\($0), " } ?? ""
            return Notice(kind: .process, level: .error, text: "omp was killed (\(name)signal \(signal))\(detail).")
        }
        if let code, code != 0 { return Notice(kind: .process, level: .error, text: "omp exited with code \(code)\(detail).") }
        return Notice(kind: .process, level: .info, text: "omp exited\(detail).")
    }

    private mutating func appendStderr(_ text: String, seq: Seq) {
        guard !text.isEmpty else { return }
        guard let index = stderrNotice, index == items.count - 1 else {
            stderrNotice = append(.notice(Notice(kind: .stderr, level: .info, text: text)), id: "stderr:\(seq)", seq: seq)
            return
        }
        items[index].content.withNotice { notice in
            if !notice.text.hasSuffix("\n") { notice.text.append("\n") }
            notice.text.append(text)
            if notice.text.count > Self.stderrLimit { notice.text = String(notice.text.suffix(Self.stderrLimit)) }
        }
        items[index].touch(seq)
    }

    // MARK: - Building blocks

    @discardableResult
    mutating func append(_ content: TranscriptItem.Content, id: String, seq: Seq?) -> Int {
        items.append(TranscriptItem(id: id, content: content, seq: seq))
        return items.count - 1
    }

    static func userMessage(_ message: JSONValue) -> UserMessage {
        UserMessage(text: OmpContent.text(of: message["content"]), imageCount: OmpContent.imageCount(of: message["content"]))
    }
}
