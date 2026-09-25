import Foundation
import IDEProtocol

extension TranscriptReducer {
    /// Replaces the whole state with the transcript in a `session.snapshot`: omp's durable entries (active branch),
    /// its `get_state`, and the dialogs the daemon still holds (timed ones expire from when the daemon received them).
    /// Journal records after `snapshot.lastSeq` apply on top; a message that was mid-stream (never persisted) continues
    /// from the partial its next `message_update` carries.
    public mutating func rebuild(from snapshot: SessionSnapshot.Result) {
        self = TranscriptReducer()
        for (position, entry) in Self.activeBranch(of: snapshot.entries).enumerated() {
            applyEntry(entry, id: "entry:\(entry["id"]?.stringValue ?? "#\(position)")")
        }
        let isStreaming = snapshot.state?["isStreaming"]?.boolValue == true
        if !isStreaming {
            // Nothing is running, so a call without a result was dropped by an omp that died mid-tool.
            for index in unfinishedTools { items[index].content.withTool { $0.status = .interrupted } }
            unfinishedTools = []
        }
        for request in snapshot.entry.pending.uiRequests {
            guard let dialog = Dialog(request: request.frame, receivedAt: request.receivedAt) else { continue }
            appendDialog(dialog, id: "dialog:\(dialog.requestId)", seq: nil)
        }
        if isStreaming {
            activity = .streaming
        } else if snapshot.state?["isSettled"]?.boolValue == false || snapshot.entry.status == .busy {
            activity = .working
        } else {
            activity = .idle
        }
        lastSeq = snapshot.lastSeq
    }

    /// Entries on the path root -> leaf of an omp `get_entries` result (`{entries, leafId}`), or every entry in order
    /// when there is no usable leaf.
    static func activeBranch(of entries: JSONValue?) -> [JSONValue] {
        let all = entries?.arrayValue ?? entries?["entries"]?.arrayValue ?? []
        guard let leafId = entries?["leafId"]?.stringValue else { return all }
        var byId: [String: JSONValue] = [:]
        for entry in all {
            if let id = entry["id"]?.stringValue { byId[id] = entry }
        }
        var path: [JSONValue] = []
        var visited: Set<String> = []
        var next: String? = leafId
        while let id = next, visited.insert(id).inserted, let entry = byId[id] {
            path.append(entry)
            next = entry["parentId"]?.stringValue
        }
        return path.isEmpty ? all : path.reversed()
    }

    private mutating func applyEntry(_ entry: JSONValue, id: String) {
        switch entry["type"]?.stringValue {
        case "message":
            guard let message = entry["message"] else { return }
            switch message["role"]?.stringValue {
            case "user":
                append(.user(Self.userMessage(message)), id: id, seq: nil)
            case "assistant":
                let assistant = Self.completedAssistant(message)
                if !assistant.isEmpty { append(.assistant(assistant), id: id, seq: nil) }
                for block in message["content"]?.arrayValue ?? [] where block["type"]?.stringValue == "toolCall" {
                    upsertTool(block: block, status: .pending, seq: nil)
                }
            case "toolResult":
                finishTool(result: message, seq: nil)
            default:
                break
            }
        case "custom" where entry["customType"]?.stringValue == "tool_execution_start":
            // omp's crash marker, written right before a tool starts (session.md).
            guard let data = entry["data"], let callId = data["toolCallId"]?.stringValue else { return }
            upsertTool(
                callId, name: data["toolName"]?.stringValue, arguments: nil, intent: data["intent"]?.stringValue, status: .running,
                seq: nil)
        case "compaction":
            let text = entry["shortSummary"]?.stringValue.map { "Context compacted: \($0)" } ?? "Context compacted."
            append(.notice(Notice(kind: .compaction, level: .info, text: text)), id: id, seq: nil)
        default:
            break
        }
    }

    static func completedAssistant(_ message: JSONValue) -> AssistantMessage {
        var blocks: [AssistantMessage.Block] = []
        for block in message["content"]?.arrayValue ?? [] {
            switch block["type"]?.stringValue {
            case "text":
                if let text = block["text"]?.stringValue, !text.isEmpty { blocks.append(.init(kind: .text, text: text)) }
            case "thinking":
                if let text = block["thinking"]?.stringValue, !text.isEmpty { blocks.append(.init(kind: .thinking, text: text)) }
            default:
                break
            }
        }
        return AssistantMessage(
            blocks: blocks, isStreaming: false, stopReason: message["stopReason"]?.stringValue,
            errorMessage: message["errorMessage"]?.stringValue, model: message["model"]?.stringValue)
    }
}
