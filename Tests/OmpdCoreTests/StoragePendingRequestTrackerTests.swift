import Foundation
import IDEProtocol
import Testing
@testable import OmpdCore

private func uiRequest(_ id: String, _ method: String, timeout: Double? = nil) -> JSONValue {
    var frame: [String: JSONValue] = ["type": "extension_ui_request", "id": .string(id), "method": .string(method), "title": "t"]
    if let timeout { frame["timeout"] = .number(timeout) }
    return .object(frame)
}

private func hostToolCall(_ id: String) -> JSONValue {
    ["type": "host_tool_call", "id": .string(id), "toolCallId": .string("toolu_\(id)"), "toolName": "echo_host", "arguments": ["message": "hi"]]
}

// `#expect` cannot wrap a mutating call, so each step's "changed" result is bound first.
@Suite struct StoragePendingRequestTrackerTests {
    @Test func answeredDialogIsNoLongerPending() {
        var tracker = PendingRequestTracker()
        let approval: JSONValue = [
            "type": "extension_ui_request", "id": "7", "method": "select",
            "title": "Allow tool: bash\nls", "options": ["Approve", "Deny"],
        ]
        let tracked = tracker.observe(ompFrame: approval)
        #expect(tracked && tracker.pending.uiRequests == [approval])
        let strayAnswer = tracker.observe(sentToOmp: ["type": "extension_ui_response", "id": "8", "value": "Approve"])
        #expect(!strayAnswer && tracker.pending.uiRequests == [approval])
        let answered = tracker.observe(sentToOmp: ["type": "extension_ui_response", "id": "7", "value": "Approve"])
        #expect(answered && tracker.pending == PendingRequests())
    }

    @Test func fireAndForgetRequestsAreNotTracked() {
        var tracker = PendingRequestTracker()
        for method in ["notify", "setStatus", "setWidget", "setTitle", "set_editor_text", "open_url"] {
            let tracked = tracker.observe(ompFrame: uiRequest(method, method))
            #expect(!tracked, "\(method)")
        }
        #expect(tracker.pending == PendingRequests())
    }

    @Test func dialogWithdrawnByOmpIsDropped() {
        var tracker = PendingRequestTracker()
        _ = tracker.observe(ompFrame: uiRequest("1", "editor"))
        _ = tracker.observe(ompFrame: uiRequest("2", "confirm"))
        let cancel: JSONValue = ["type": "extension_ui_request", "id": "3", "method": "cancel", "targetId": "1"]
        let withdrawn = tracker.observe(ompFrame: cancel)
        let withdrawnAgain = tracker.observe(ompFrame: cancel)
        #expect(withdrawn && !withdrawnAgain)
        #expect(tracker.pending.uiRequests == [uiRequest("2", "confirm")])
    }

    @Test func hostToolCallClearsOnCancelOrOnAResultOmpAccepts() {
        var tracker = PendingRequestTracker()
        _ = tracker.observe(ompFrame: hostToolCall("h1"))
        _ = tracker.observe(ompFrame: hostToolCall("h2"))
        let cancelled = tracker.observe(ompFrame: ["type": "host_tool_cancel", "id": "c1", "targetId": "h1"])
        #expect(cancelled && tracker.pending.hostToolCalls == [hostToolCall("h2")])

        // omp keeps waiting through progress updates and results without a `content` array.
        let progress = tracker.observe(sentToOmp: ["type": "host_tool_update", "id": "h2", "partialResult": ["content": []]])
        let malformed = tracker.observe(sentToOmp: ["type": "host_tool_result", "id": "h2", "result": "done"])
        #expect(!progress && !malformed && tracker.pending.hostToolCalls == [hostToolCall("h2")])
        let completed = tracker.observe(sentToOmp: [
            "type": "host_tool_result", "id": "h2", "result": ["content": [["type": "text", "text": "done"]]],
        ])
        #expect(completed && tracker.pending == PendingRequests())
    }

    @Test func timedDialogExpiresWhenOmpResolvesItSilently() {
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        var tracker = PendingRequestTracker()
        _ = tracker.observe(ompFrame: uiRequest("1", "confirm", timeout: 30_000), receivedAt: t0)
        _ = tracker.observe(ompFrame: uiRequest("2", "select"), receivedAt: t0)
        #expect(tracker.nextDeadline == t0.addingTimeInterval(30))
        let early = tracker.expire(now: t0.addingTimeInterval(29.999))
        #expect(early.isEmpty)
        let lapsed = tracker.expire(now: t0.addingTimeInterval(30))
        #expect(lapsed == [uiRequest("1", "confirm", timeout: 30_000)])
        #expect(tracker.pending.uiRequests == [uiRequest("2", "select")])
        #expect(tracker.nextDeadline == nil)
    }

    @Test func restoredTimedDialogCountsFromRestoreTime() {
        let restoredAt = Date(timeIntervalSince1970: 1_790_000_000)
        let dialog = uiRequest("1", "input", timeout: 1_000)
        var tracker = PendingRequestTracker(restoring: PendingRequests(uiRequests: [dialog]), restoredAt: restoredAt)
        #expect(tracker.pending.uiRequests == [dialog])
        #expect(tracker.nextDeadline == restoredAt.addingTimeInterval(1))
        let answered = tracker.observe(sentToOmp: ["type": "extension_ui_response", "id": "1", "cancelled": true])
        #expect(answered && tracker.nextDeadline == nil)
        let lapsed = tracker.expire(now: restoredAt.addingTimeInterval(5))
        #expect(lapsed.isEmpty)
    }

    @Test func clearReturnsEverythingAbandoned() {
        var tracker = PendingRequestTracker()
        let dialog = uiRequest("1", "input", timeout: 5_000)
        _ = tracker.observe(ompFrame: dialog)
        _ = tracker.observe(ompFrame: hostToolCall("h1"))
        let abandoned = tracker.clear()
        #expect(abandoned == PendingRequests(uiRequests: [dialog], hostToolCalls: [hostToolCall("h1")]))
        #expect(tracker.pending == PendingRequests())
        #expect(tracker.nextDeadline == nil)
    }
}
