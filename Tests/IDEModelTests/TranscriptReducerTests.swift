import Foundation
@testable import IDEModel
import Testing

@Suite struct TranscriptReducerTests {
    // MARK: - Recorded sequences

    @Test func streamingTextGrowsInPlaceAndMatchesTheFinalMessage() throws {
        let records = try Fixture.records("bash-approve")
        var reducer = TranscriptReducer()
        var streamed: [String: String] = [:] // messageId -> text deltas so far
        var streamingItem: (id: String, index: Int)?
        for record in records {
            let countBefore = reducer.items.count
            reducer.apply(record)
            let frame = record.payload
            guard frame["type"]?.stringValue == "message_update",
                  frame["assistantMessageEvent"]?["type"]?.stringValue == "text_delta",
                  let messageId = frame["messageId"]?.stringValue
            else { continue }
            streamed[messageId, default: ""] += frame["assistantMessageEvent"]?["delta"]?.stringValue ?? ""
            #expect(reducer.items.count == countBefore, "a delta never adds an item")
            let index = try #require(reducer.items.lastIndex { $0.assistant != nil })
            if let streamingItem, streamingItem.id == reducer.items[index].id {
                #expect(streamingItem.index == index, "the streaming message keeps its row")
            }
            streamingItem = (reducer.items[index].id, index)
            let message = try #require(reducer.items[index].assistant)
            #expect(message.isStreaming)
            #expect(message.text(.text) == streamed[messageId])
        }

        let assistants = reducer.items.compactMap(\.assistant)
        #expect(assistants.count == 2)
        #expect(assistants.allSatisfy { !$0.isStreaming })
        #expect(assistants[0].text(.text).isEmpty)
        #expect(assistants[0].text(.thinking).hasPrefix("The user is asking me to run a specific bash command exactly once"))
        #expect(assistants[0].stopReason == "toolUse")
        #expect(assistants[1].blocks.map(\.kind) == [.thinking, .text])
        #expect(assistants[1].text(.text) == "Done.")
        #expect(assistants[1].stopReason == "stop")
        #expect(assistants[1].model == "claude-haiku-4-5")
        #expect(reducer.activity == .idle)
    }

    @Test func toolCallLifecycle() throws {
        let records = try Fixture.records("bash-approve")
        var reducer = TranscriptReducer()
        var statuses: [ToolCall.Status] = []
        for record in records {
            reducer.apply(record)
            if let status = reducer.items.lazy.compactMap(\.tool).first?.status, statuses.last != status { statuses.append(status) }
        }
        #expect(statuses == [.composing, .pending, .running, .succeeded])

        let tool = try #require(reducer.items.compactMap(\.tool).first)
        #expect(tool.toolCallId == "toolu_018KUTrkLsw2pFgA9E5RSK6k")
        #expect(tool.name == "bash")
        #expect(tool.summary == "echo spike-bash-ok")
        #expect(tool.intent == "Running specified command")
        #expect(tool.output == "spike-bash-ok\n\n\nWall time: 0.06 seconds")
        #expect(!tool.outputIsTruncated)
        #expect(reducer.items.count { $0.tool != nil } == 1, "start/update/end and the tool result all land on one card")
    }

    @Test func approvalRequestIsAnsweredThroughTheDaemon() throws {
        let records = try Fixture.records("bash-approve")
        let requestIndex = try #require(records.firstIndex { $0.payload["method"]?.stringValue == "select" })
        let pending = reduce(records[...requestIndex])
        let dialog = try #require(pending.items.last?.dialog)
        #expect(dialog.requestId == "158d569562c98aeb")
        #expect(dialog.kind == .select)
        #expect(dialog.approval == Dialog.Approval(toolName: "bash", details: ["Command: echo spike-bash-ok"]))
        #expect(dialog.options.map(\.label) == ["Approve", "Deny"])
        #expect(dialog.state == .pending)
        #expect(dialog.expiresAt == nil)
        #expect(pending.pendingDialogs == [dialog])

        // The fixture predates protocol 2: its `uiAnswered` carries no response.
        let answered = reduce(records[...(requestIndex + 1)])
        #expect(records[requestIndex + 1].kind == .daemon)
        #expect(answered.items.compactMap(\.dialog).map(\.state) == [.answered(nil)])
        #expect(answered.pendingDialogCount == 0)

        var approved = pending
        approved.apply(try record(records[requestIndex].seq + 1, .uiAnswered(requestId: dialog.requestId, response: ["value": "Approve"])))
        #expect(approved.items.compactMap(\.dialog).map(\.state) == [.answered(.value("Approve"))])

        let done = reduce(records)
        #expect(done.items.map(Self.shape) == [
            "notice:process", "user", "assistant", "tool:succeeded", "dialog:answered", "assistant", "notice:process",
        ])
    }

    @Test func cancelWithdrawsTheAskAndTheAbortedRunIsReported() throws {
        let reducer = reduce(try Fixture.records("abort-pending-ask"))
        #expect(reducer.items.map(Self.shape) == [
            "notice:process", "user", "assistant", "tool:failed", "dialog:withdrawn", "assistant", "notice:outcome",
            "notice:process",
        ])
        let dialog = try #require(reducer.items.compactMap(\.dialog).first)
        #expect(dialog.title == "Pick a color")
        #expect(dialog.approval == nil)
        #expect(dialog.options == [
            .init(label: "Red", description: "warm"), .init(label: "Green (Recommended)"), .init(label: "Blue"),
            .init(label: "Other (type your own)"),
        ])
        let tool = try #require(reducer.items.compactMap(\.tool).first)
        #expect(tool.name == "ask")
        #expect(tool.summary == "Pick a color")
        #expect(tool.output == "Ask input was cancelled")
        let aborted = try #require(reducer.items.compactMap(\.assistant).last)
        #expect(aborted.stopReason == "aborted")
        #expect(aborted.errorMessage == "Interrupted by user")
        #expect(reducer.activity == .idle)
    }

    @Test func dialogsAreAnsweredCancelledOrExpire() throws {
        let reducer = reduce(try Fixture.records("ext-methods"))
        let dialogs = reducer.items.compactMap(\.dialog)
        #expect(dialogs.map(\.kind) == [.select, .confirm, .input, .editor, .select, .confirm, .input, .editor, .confirm, .select, .input])
        #expect(dialogs.map(\.state) == Array(repeating: .answered(nil), count: 8) + Array(repeating: .expired, count: 3))
        #expect(dialogs[0].options == [.init(label: "Alpha", description: "first option"), .init(label: "Beta")])
        #expect(dialogs[1].message == "Proceed?")
        #expect(dialogs[2].placeholder == "placeholder text")
        #expect(dialogs[3].prefill == "prefill text")
        #expect(reducer.nextDialogDeadline == nil)

        let notifications = reducer.items.compactMap(\.notice).filter { $0.kind == .extensionMessage }
        #expect(notifications.map(\.level) == [.info, .warning, .error])
        #expect(notifications.map(\.text) == ["spike notify info", "spike notify warning", "spike notify error"])
        #expect(reducer.items.count == 1 + 3 + 11 + 1, "status/widget/title/editor-text frames add nothing")
    }

    @Test func aTimedDialogExpiresAtItsDeadline() throws {
        var reducer = TranscriptReducer()
        reducer.apply(record(1, ["type": "extension_ui_request", "id": "d1", "method": "confirm", "title": "Go?", "timeout": 1500]))
        let deadline = testDate.addingTimeInterval(1.5)
        #expect(reducer.nextDialogDeadline == deadline)
        reducer.expireDialogs(asOf: deadline.addingTimeInterval(-0.001))
        #expect(reducer.pendingDialogs.map(\.requestId) == ["d1"])
        reducer.expireDialogs(asOf: deadline)
        #expect(reducer.items.compactMap(\.dialog).map(\.state) == [.expired])
        #expect(reducer.nextDialogDeadline == nil)
        reducer.apply(try record(2, .uiAnswered(requestId: "d1", response: ["confirmed": true])))
        #expect(reducer.items.compactMap(\.dialog).map(\.state) == [.expired], "a late answer does not revive it")
    }

    @Test func lostRangeFadesWhatOmpNeverSavedAndProcessesKeepTheirOwnMessageIds() throws {
        let reducer = reduce(try Fixture.records("sigkill-stream"))
        #expect(reducer.items.map(Self.shape) == [
            "notice:process", "user", "assistant", "user", "assistant", "notice:process", "notice:lost", "notice:process",
            "user", "assistant",
        ])
        #expect(reducer.items.map(\.isLost) == [false, false, false, false, true, false, false, false, false, false])

        let assistants = reducer.items.compactMap(\.assistant)
        // Both processes named a message `msg-2`; the resumed one must not write into the first one's row.
        #expect(assistants[0].text(.text) == "WARMUP-OK")
        let killed = assistants[1]
        #expect(killed.text(.text).hasPrefix("# The History of Lighthouses: Guiding Humanity Through the Ages"))
        #expect(killed.text(.text).hasSuffix("The earliest forms of lighthouse structures"))
        #expect(!killed.isStreaming)
        #expect(killed.wasInterrupted)
        #expect(assistants[2].text(.text).hasPrefix("RESUMED-OK\nPrevious turn was a warmup check"))
        #expect(!assistants[2].wasInterrupted)

        let notices = reducer.items.compactMap(\.notice)
        #expect(notices[1] == Notice(kind: .process, level: .error, text: "omp was killed (SIGKILL, signal 9)."))
        #expect(notices[2].kind == .lost(fromSeq: 26, toSeq: 67))
        #expect(notices[3].text == "omp 18.3.1 resumed the session (pid 5002).")
    }

    @Test(arguments: ["bash-approve", "abort-pending-ask", "ext-methods", "sigkill-stream"])
    func replayIsIdempotent(_ fixture: String) throws {
        let records = try Fixture.records(fixture)
        let reference = reduce(records)
        #expect(reduce(records) == reference, "a fresh replay after a resync rebuilds the same items")

        // Re-subscribing replays from an earlier seq than was applied: the overlap changes nothing.
        for cut in [1, records.count / 3, records.count / 2, records.count - 1] {
            var overlapping = reduce(records[..<cut])
            for record in records { overlapping.apply(record) }
            #expect(overlapping == reference, "overlap after \(cut) records")
        }
        var twice = reference
        for record in records { twice.apply(record) }
        #expect(twice == reference)
    }

    // MARK: - Snapshot rebuild

    @Test func rebuildFromSnapshotShowsTheActiveBranch() throws {
        var reducer = reduce(try Fixture.records("bash-approve"))
        reducer.rebuild(from: try Fixture.snapshot("snapshot-eof-tool"))
        #expect(reducer.lastSeq == 57)
        #expect(reducer.items.map(Self.shape) == ["user", "tool:failed"], "the tool-only assistant turn renders as its card")
        #expect(reducer.items.first?.user?.text.hasPrefix("Use the bash tool exactly once") == true)
        let tool = try #require(reducer.items.last?.tool)
        #expect(tool.name == "bash")
        #expect(tool.summary == "/bin/sleep 30; echo SLEPT-OK")
        #expect(tool.output == "Command aborted")
        #expect(reducer.activity == .idle)
        #expect(reducer.items.allSatisfy { $0.seqs == nil })
    }

    @Test func rebuildMarksACallWithoutResultInterrupted() throws {
        var reducer = TranscriptReducer()
        reducer.rebuild(from: try Fixture.snapshot("snapshot-sigkill-tool"))
        #expect(reducer.items.map(Self.shape) == ["user", "tool:interrupted"])
    }

    @Test func rebuildRepresentsHeldDialogsWithTheirArrivalTime() throws {
        var snapshot = try Fixture.snapshot("snapshot-eof-tool")
        let arrived = testDate.addingTimeInterval(-45)
        let frames: [JSONValue] = [
            ["type": "extension_ui_request", "id": "a1", "method": "select", "title": "Allow tool: edit\nFile: a.txt", "options": ["Approve", "Deny"]],
            ["type": "extension_ui_request", "id": "a2", "method": "input", "title": "Name?", "timeout": 60_000],
            ["type": "extension_ui_request", "id": "a3", "method": "setWidget", "widgetKey": "autoresearch"],
        ]
        snapshot.entry.pending.uiRequests = frames.map { HeldRequest(frame: $0, receivedAt: arrived) }
        var reducer = TranscriptReducer()
        reducer.rebuild(from: snapshot)
        #expect(reducer.pendingDialogs.map(\.requestId) == ["a1", "a2"])
        #expect(reducer.pendingDialogs.first?.approval == Dialog.Approval(toolName: "edit", details: ["File: a.txt"]))
        #expect(reducer.nextDialogDeadline == arrived.addingTimeInterval(60), "the timeout runs from when the daemon got it")
    }

    @Test func aMessageJoinedMidStreamIsSeededFromItsPartialOnce() throws {
        var reducer = TranscriptReducer()
        reducer.rebuild(from: try Fixture.snapshot("snapshot-eof-tool"))
        let partial: JSONValue = ["role": "assistant", "model": "claude-haiku-4-5", "content": [["type": "text", "text": "Hello"]]]
        reducer.apply(record(58, [
            "type": "message_update", "messageId": "msg-9", "message": partial,
            "assistantMessageEvent": ["type": "text_delta", "contentIndex": 0, "delta": "lo"],
        ]))
        reducer.apply(record(59, [
            "type": "message_update", "messageId": "msg-9", "message": partial,
            "assistantMessageEvent": ["type": "text_delta", "contentIndex": 0, "delta": " world"],
        ]))
        #expect(reducer.items.last?.assistant?.text(.text) == "Hello world")
        #expect(reducer.items.last?.assistant?.isStreaming == true)
        reducer.apply(record(60, [
            "type": "message_end", "messageId": "msg-9",
            "message": ["role": "assistant", "content": [["type": "text", "text": "Hello world"]], "stopReason": "stop"],
        ]))
        #expect(reducer.items.count { $0.assistant != nil } == 1)
        #expect(reducer.items.last?.assistant == AssistantMessage(
            blocks: [.init(kind: .text, text: "Hello world")], isStreaming: false, stopReason: "stop", model: "claude-haiku-4-5"))
    }

    @Test func exitMidRunInterruptsEverythingStillOpen() throws {
        let records = try Fixture.records("bash-approve")
        let requestIndex = try #require(records.firstIndex { $0.payload["method"]?.stringValue == "select" })
        var reducer = reduce(records[...requestIndex])
        reducer.apply(try record(records[requestIndex].seq + 1, .exited(code: nil, signal: 9, sessionExitKind: nil)))
        #expect(reducer.items.compactMap(\.tool).map(\.status) == [.interrupted])
        #expect(reducer.items.compactMap(\.dialog).map(\.state) == [.abandoned])
        #expect(reducer.activity == .idle)
    }

    @Test func stderrLinesCollectInOneNoticeUntilSomethingElseIsShown() throws {
        var reducer = TranscriptReducer()
        reducer.apply(record(1, ["text": "warn: a"], kind: .stderr))
        reducer.apply(record(2, ["text": "warn: b"], kind: .stderr))
        reducer.apply(record(3, ["type": "notice", "level": "warning", "message": "disk almost full", "source": "session-persistence"]))
        reducer.apply(record(4, ["text": "warn: c"], kind: .stderr))
        #expect(reducer.items.compactMap(\.notice) == [
            Notice(kind: .stderr, level: .info, text: "warn: a\nwarn: b"),
            Notice(kind: .message, level: .warning, text: "disk almost full"),
            Notice(kind: .stderr, level: .info, text: "warn: c"),
        ])
    }

    @Test func retryCompactionAndErrorsBecomeNotices() throws {
        var reducer = TranscriptReducer()
        reducer.apply(record(1, ["type": "agent_start"]))
        #expect(reducer.activity == .streaming)
        reducer.apply(record(2, ["type": "auto_retry_start", "attempt": 1, "maxAttempts": 3, "delayMs": 2000, "errorMessage": "overloaded"]))
        reducer.apply(record(3, ["type": "auto_retry_end", "success": true, "attempt": 1]))
        reducer.apply(record(4, ["type": "auto_compaction_start", "reason": "threshold", "action": "context-full"]))
        reducer.apply(record(5, ["type": "auto_compaction_end", "action": "context-full", "aborted": false, "willRetry": false]))
        reducer.apply(record(6, ["type": "agent_end", "messages": [], "isTerminal": true, "yielded": true]))
        #expect(reducer.activity == .working)
        reducer.apply(record(7, [
            "type": "prompt_result", "id": "p1", "agentInvoked": true, "status": "error", "sessionSettled": true,
            "error": ["message": "rate limited", "retryable": true],
        ]))
        #expect(reducer.activity == .idle)
        #expect(reducer.items.compactMap(\.notice).map(\.text) == [
            "Retrying (attempt 1/3) in 2.0s: overloaded", "Retry succeeded.", "Compacting context (threshold)…",
            "Context compacted.", "rate limited",
        ])
        #expect(reducer.items.last?.notice?.level == .error)
    }

    /// `kind[:state]` of an item, for comparing a transcript's shape.
    static func shape(_ item: TranscriptItem) -> String {
        switch item.content {
        case .user: "user"
        case .assistant: "assistant"
        case .tool(let tool): "tool:\(tool.status)"
        case .dialog(let dialog):
            if case .answered = dialog.state { "dialog:answered" } else { "dialog:\(dialog.state)" }
        case .notice(let notice):
            switch notice.kind {
            case .lost: "notice:lost"
            default: "notice:\(notice.kind)"
            }
        }
    }
}
