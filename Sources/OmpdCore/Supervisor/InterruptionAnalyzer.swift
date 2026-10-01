import Foundation
import IDEProtocol

/// Reads what a dead omp left unfinished from its session JSONL and the artifact tree next
/// to it, before the session is resumed. omp's own resume repair drops dangling tool calls from model context,
/// so this is the only record of them the resumed agent can be told about.
///
/// The session file is read as a line sequence (the branch its last line ends on, which is what `--resume` follows),
/// limited to its last `window` bytes.
enum InterruptionAnalyzer {
    /// Custom entry ompd appends through the bridge (`entry.append`) once an interruption was handled (continued or
    /// left): IDE bookkeeping, not model context. An interruption before one is never reported again.
    static let markerType = "com.omp-ide.interrupted"

    static let mainWindow = 4 << 20
    static let agentWindow = 1 << 20

    /// The interruption the omp that served `sessionFile` since `since` (its spawn; nil when unknown) left behind, or
    /// nil when nothing was left mid-turn. `cause` says how omp ended.
    static func analyze(sessionFile: String, since: Date?, cause: String, now: Date = Date()) -> Interruption? {
        guard let main = TranscriptState.read(path: sessionFile, since: since, window: mainWindow) else { return nil }
        var evalUsed = main.evalUsed
        // Agents written to before the last handled interruption (or the dead run's start) are not the dead run's.
        let floor = [since, main.lastMarkerAt].compactMap { $0 }.max()
        var agents: [InterruptedAgent] = []
        let artifacts = String(sessionFile.dropLast(sessionFile.hasSuffix(".jsonl") ? 6 : 0))
        for transcript in agentTranscripts(in: artifacts) {
            if let floor, transcript.modified < floor { continue }
            guard let state = TranscriptState.read(path: transcript.path, since: since, window: agentWindow) else { continue }
            evalUsed = evalUsed || state.evalUsed
            // An output says the agent finished, unless the dead process's teardown aborted calls of it: omp then writes
            // whatever the agent had said so far as its output (seen on SIGHUP when ompd died mid-`bash`).
            if transcript.hasOutput && !state.teardownAbortedCalls { continue }
            guard state.interrupted else { continue }
            agents.append(InterruptedAgent(id: transcript.id, pendingToolCalls: state.pendingToolCalls))
        }
        let interruption = Interruption(
            detectedAt: now, cause: cause, mainInterrupted: main.interrupted, pendingToolCalls: main.pendingToolCalls,
            agents: agents.sorted { $0.id < $1.id }, evalKernelsLost: evalUsed)
        return interruption.isEmpty ? nil : interruption
    }

    /// `old` (still waiting for a decision) and `new` (found at a later death) as one interruption: everything either
    /// left unfinished, the first cause.
    static func merge(_ old: Interruption?, _ new: Interruption?) -> Interruption? {
        guard let old else { return new }
        guard let new else { return old }
        var agents = old.agents
        for agent in new.agents {
            if let index = agents.firstIndex(where: { $0.id == agent.id }) {
                agents[index].pendingToolCalls = union(agents[index].pendingToolCalls, agent.pendingToolCalls)
            } else {
                agents.append(agent)
            }
        }
        return Interruption(
            detectedAt: old.detectedAt, cause: old.cause, mainInterrupted: old.mainInterrupted || new.mainInterrupted,
            pendingToolCalls: union(old.pendingToolCalls, new.pendingToolCalls), agents: agents.sorted { $0.id < $1.id },
            evalKernelsLost: old.evalKernelsLost || new.evalKernelsLost)
    }

    private static func union(_ a: [InterruptedToolCall], _ b: [InterruptedToolCall]) -> [InterruptedToolCall] {
        a + b.filter { call in !a.contains { $0.toolCallId == call.toolCallId } }
    }

    // MARK: - Subagents

    /// A subagent's transcript that may be unfinished: `<id>.jsonl` anywhere under the artifacts dir without a
    /// tombstone (killed; checked first, a killed agent also has an empty `<id>.md`). `hasOutput`: a non-empty `<id>.md`
    /// (its output), which says it finished unless omp's teardown wrote it.
    struct AgentTranscript {
        var id: String
        var path: String
        var modified: Date
        var hasOutput: Bool
    }

    static func agentTranscripts(in directory: String) -> [AgentTranscript] {
        let fm = FileManager.default
        guard let walker = fm.enumerator(
            at: URL(filePath: directory), includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles])
        else { return [] }
        var found: [AgentTranscript] = []
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            let path = url.path(percentEncoded: false)
            if fm.fileExists(atPath: path + ".tombstone") { continue }
            let output = url.deletingPathExtension().appendingPathExtension("md").path(percentEncoded: false)
            let outputSize = (try? fm.attributesOfItem(atPath: output))?[.size] as? Int ?? 0
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            found.append(AgentTranscript(
                id: url.deletingPathExtension().lastPathComponent, path: path,
                modified: values?.contentModificationDate ?? .distantPast, hasOutput: outputSize > 0))
        }
        return found
    }
}

/// How one agent's transcript (the main session file or a subagent's) ends.
struct TranscriptState: Equatable {
    /// The agent was mid-turn: its last message is a prompt or a tool result nothing answered, tool calls without
    /// results, or a reply the process's own teardown aborted.
    var interrupted: Bool
    var pendingToolCalls: [InterruptedToolCall]
    /// `eval` ran since the dead run's start.
    var evalUsed: Bool
    /// When the newest `com.omp-ide.interrupted` marker was written.
    var lastMarkerAt: Date?
    /// The dead run's `session_exit` lists tool calls omp aborted in its teardown: the agent was mid-call.
    var teardownAbortedCalls = false

    private struct Message {
        var index: Int
        var role: String
        var stopReason: String?
        var errorMessage: String?
        /// Assistant tool-call blocks (`{type:"toolCall", id, name, arguments}`).
        var toolCalls: [JSONValue]
    }

    /// An abort that ends the turn on purpose: the user's (Esc) or omp's after its retries ran out.
    static func endsTurnOnPurpose(abort errorMessage: String?) -> Bool {
        guard let errorMessage else { return false }
        return errorMessage == "Interrupted by user" || errorMessage.hasPrefix("Aborted after ")
    }

    /// nil when the file cannot be read.
    static func read(path: String, since: Date?, window: Int) -> TranscriptState? {
        guard let entries = tail(path: path, window: window) else { return nil }
        var lastMarker: (index: Int, at: Date?)?
        var lastMessage: Message?
        var exits: [(index: Int, recordedAt: Date?, pending: [JSONValue])] = []
        var starts: [(index: Int, at: Date?, data: JSONValue)] = []
        var results: [(index: Int, toolCallId: String)] = []

        for (index, entry) in entries.enumerated() {
            let at = entry["timestamp"]?.stringValue.flatMap(SessionFileTail.parseTimestamp)
            switch entry["type"]?.stringValue {
            case "message":
                guard let message = entry["message"], let role = message["role"]?.stringValue,
                      ["user", "assistant", "toolResult"].contains(role)
                else { continue }
                if role == "toolResult", let id = message["toolCallId"]?.stringValue { results.append((index, id)) }
                lastMessage = Message(
                    index: index, role: role, stopReason: message["stopReason"]?.stringValue,
                    errorMessage: message["errorMessage"]?.stringValue,
                    toolCalls: (message["content"]?.arrayValue ?? []).filter { $0["type"]?.stringValue == "toolCall" })
            case "custom":
                let data = entry["data"] ?? .null
                switch entry["customType"]?.stringValue {
                case InterruptionAnalyzer.markerType:
                    lastMarker = (index, data["recordedAt"]?.stringValue.flatMap(SessionFileTail.parseTimestamp) ?? at)
                case "session_exit":
                    exits.append((
                        index, data["recordedAt"]?.stringValue.flatMap(SessionFileTail.parseTimestamp) ?? at,
                        data["pendingToolCalls"]?.arrayValue ?? []))
                case "tool_execution_start":
                    starts.append((index, at, data))
                default:
                    break
                }
            default:
                break
            }
        }

        let floor = (lastMarker?.index ?? -1) + 1
        func inRun(_ index: Int, _ at: Date?) -> Bool {
            guard index >= floor else { return false }
            guard let since else { return true }
            return (at ?? .distantFuture) >= since.addingTimeInterval(-0.001)
        }
        let evalUsed = starts.contains { inRun($0.index, $0.at) && $0.data["toolName"]?.stringValue == "eval" }
        let markerAt = lastMarker?.at
        let runExit = exits.last(where: { inRun($0.index, $0.recordedAt) })
        let teardownAborted = !(runExit?.pending.isEmpty ?? true)
        let notInterrupted = TranscriptState(
            interrupted: false, pendingToolCalls: [], evalUsed: evalUsed, lastMarkerAt: markerAt,
            teardownAbortedCalls: teardownAborted)

        // Handled already: a marker after the last message.
        guard let message = lastMessage, message.index >= floor else { return notInterrupted }
        let interrupted: Bool
        switch message.role {
        case "user", "toolResult":
            interrupted = true
        default:
            switch message.stopReason {
            case "toolUse":
                interrupted = true
            case "aborted":
                // Only two aborts end a turn on purpose: the user's (Esc, "Interrupted by user") and omp giving up on
                // retries ("Aborted after N retry attempts"). Any other was the process's own teardown ("Request was
                // aborted", "Operation aborted", persisted around its `session_exit` or with none at all: SIGTERM,
                // SIGHUP, a graceful stop) or omp's synthetic abort for a turn a previous process never finished.
                interrupted = !TranscriptState.endsTurnOnPurpose(abort: message.errorMessage)
            default:
                interrupted = false
            }
        }
        guard interrupted else { return notInterrupted }

        let answered = Set(results.filter { $0.index >= floor }.map(\.toolCallId))
        var pending: [InterruptedToolCall] = []
        func add(_ id: String?, _ name: String?, arguments: JSONValue?, intent: String?) {
            guard let id, !pending.contains(where: { $0.toolCallId == id }) else { return }
            pending.append(InterruptedToolCall(
                toolCallId: id, toolName: name ?? "tool", summary: summary(intent: intent, arguments: arguments)))
        }
        // `session_exit.pendingToolCalls` lists calls omp aborted itself (their "aborted" results follow it).
        if let exit = runExit {
            for call in exit.pending {
                add(call["toolCallId"]?.stringValue, call["toolName"]?.stringValue, arguments: call["args"],
                    intent: call["intent"]?.stringValue)
            }
        }
        for start in starts where inRun(start.index, start.at) {
            let id = start.data["toolCallId"]?.stringValue
            guard let id, !answered.contains(id) else { continue }
            add(id, start.data["toolName"]?.stringValue, arguments: start.data["args"], intent: start.data["intent"]?.stringValue)
        }
        // Requested by the last reply but never started.
        for call in message.toolCalls {
            guard let id = call["id"]?.stringValue, !answered.contains(id) else { continue }
            add(id, call["name"]?.stringValue, arguments: call["arguments"], intent: call["arguments"]?["i"]?.stringValue)
        }
        return TranscriptState(
            interrupted: true, pendingToolCalls: pending, evalUsed: evalUsed, lastMarkerAt: markerAt,
            teardownAbortedCalls: teardownAborted)
    }

    /// One line for people and the model: what the call acts on (its command, path or url argument), else its intent,
    /// else the arguments.
    static func summary(intent: String?, arguments: JSONValue?) -> String {
        let text = [arguments?["command"]?.stringValue, arguments?["path"]?.stringValue, arguments?["url"]?.stringValue,
                    intent, arguments?["i"]?.stringValue]
            .compactMap { $0 }.first { !$0.isEmpty }
            ?? (arguments.flatMap { try? String(decoding: JSONEncoder().encode($0), as: UTF8.self) } ?? "")
        let line = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        return line.count > 160 ? String(line.prefix(159)) + "…" : line
    }

    /// Entries of the last `window` bytes of `path`, oldest first; a partial first line is skipped.
    private static func tail(path: String, window: Int) -> [JSONValue]? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(window) ? size - UInt64(window) : 0
        guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd() else { return nil }
        let decoder = JSONDecoder()
        var entries: [JSONValue] = []
        var lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)[...]
        if start > 0, !lines.isEmpty { lines = lines.dropFirst() }
        for line in lines {
            if let entry = try? decoder.decode(JSONValue.self, from: line) { entries.append(entry) }
        }
        return entries
    }
}
