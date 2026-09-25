import Darwin
import Foundation
import IDEProtocol
import Testing

@testable import OmpdCore

/// `SessionSupervisor` against the scripted fake omp (`FakeOmp`).
@Suite struct SupervisorTests {
    @Test func startSpawnsWithTheLaunchSpecAndAdoptsOmpsIdentity() async throws {
        let fixture = try await SupervisorFixture { entry in
            entry.launch.approvalMode = "yolo"
            entry.launch.model = "anthropic/claude-haiku-4-5"
            entry.launch.extraArgs = ["--thinking", "off"]
        }
        try await fixture.supervisor.start(.fresh)

        let entry = try await fixture.entry
        #expect(entry.sessionFile == fixture.omp.sessionFile)
        #expect(entry.sessionId == "fake-session")
        #expect(entry.status == .settled)
        let sessionDir = try #require(entry.launch.sessionDir)
        #expect(fixture.omp.lines("argv") == [
            "--mode rpc-ui --session-dir \(sessionDir) --approval-mode yolo --model anthropic/claude-haiku-4-5 -e /fake/ide-bridge.ts --thinking off",
        ])
        #expect(fixture.omp.received.contains { $0["type"] == "set_subagent_subscription" && $0["level"] == "events" })
        let pid = try #require(await fixture.supervisor.pid)
        let events = try await fixture.daemonEvents()
        #expect(events.contains(.spawned(pid: pid, ompVersion: "18.3.1", resumed: false)))
        #expect(events.filter { if case .statusChanged = $0 { true } else { false } } == [.statusChanged(.starting), .statusChanged(.settled)])
        // Without a bridge the session still runs, with the reason journaled.
        #expect(events.contains { if case .notice(_, let message) = $0 { message.contains("ide-bridge") } else { false } })
        await fixture.supervisor.stop(.user)
    }

    @Test func promptFramesAreJournaledAndDriveTheStatus() async throws {
        let fixture = try await SupervisorFixture()
        try await fixture.supervisor.start(.fresh)
        let data = try await fixture.supervisor.command(["type": "prompt", "message": "hello", "id": "client-chosen"])
        #expect(data == .null)
        try await eventually("session_settled journaled") {
            try await fixture.ompFrames().contains { $0["type"] == "session_settled" }
        }
        let frames = try await fixture.ompFrames()
        #expect(frames.map { $0["type"]?.stringValue ?? "?" } == [
            "response", "agent_start", "message_update", "agent_end", "prompt_result", "session_settled",
        ])
        // The client's id never reaches omp; omp's own request id links the ack to its prompt_result.
        let sent = try #require(fixture.omp.received.first { $0["type"] == "prompt" })
        #expect(sent["id"] != "client-chosen")
        #expect(frames[0]["id"] == sent["id"] && frames[4]["id"] == sent["id"])
        let statuses = try await fixture.daemonEvents().compactMap { if case .statusChanged(let s) = $0 { s } else { nil } }
        #expect(statuses == [.starting, .settled, .busy, .settled])
        let entry = try await fixture.entry
        #expect(entry.status == .settled && entry.lastSettledAt != nil)
        #expect(entry.lastSeq == (try await fixture.records()).last?.seq)
        // Pure queries are answered but not journaled.
        _ = try await fixture.supervisor.command(["type": "get_state"])
        #expect(try await fixture.ompFrames().count == frames.count)
        await fixture.supervisor.stop(.user)
    }

    @Test func refusedCommandsSurfaceOmpsError() async throws {
        let fixture = try await SupervisorFixture()
        try await fixture.supervisor.start(.fresh)
        await #expect(throws: DaemonError(.ompError, "fail: scripted failure [E_FAKE]")) {
            try await fixture.supervisor.command(["type": "fail"])
        }
        await #expect(throws: DaemonError.self) { try await fixture.supervisor.command(["no": "type"]) }
        await fixture.supervisor.stop(.user)
    }

    @Test func firstPromptIsSavedAndOwnedBeforeOmpSeesIt() async throws {
        let order = Order()
        let locks = FakeLocks(onAcquire: { file in
            let promptSeen = fakeOmpLines(nextTo: file, "stdin").contains { $0.contains(#""type":"prompt""#) }
            order.note(promptSeen ? "lock after prompt" : "lock")
        })
        let fixture = try await SupervisorFixture(bridgeConnects: true, locks: locks)
        let omp = fixture.omp
        await fixture.bridge.setOnCall { method in
            order.note(method + (omp.received.contains { $0["type"] == "prompt" } ? " after prompt" : ""))
        }
        try await fixture.supervisor.start(.fresh)
        _ = try await fixture.supervisor.command(["type": "prompt", "message": "first"])
        _ = try await fixture.supervisor.command(["type": "prompt", "message": "second", "streamingBehavior": "followUp"])

        #expect(order.values == ["session.ensureOnDisk", "lock"])
        #expect(locks.held == [omp.sessionFile])
        #expect(omp.received.filter { $0["type"] == "prompt" }.count == 2)
        await fixture.supervisor.stop(.user)
        #expect(locks.held.isEmpty)
    }

    @Test func promptIsRefusedWhenAnotherProcessOwnsTheNewSessionFile() async throws {
        let locks = FakeLocks()
        let fixture = try await SupervisorFixture(bridgeConnects: true, locks: locks)
        locks.holdElsewhere(fixture.omp.sessionFile)
        try await fixture.supervisor.start(.fresh)
        await #expect(throws: DaemonError.self) { try await fixture.supervisor.command(["type": "prompt", "message": "x"]) }
        #expect(!fixture.omp.received.contains { $0["type"] == "prompt" })
        await fixture.supervisor.stop(.user)
    }

    @Test func gracefulStopClosesStdinAndWaitsForTheExit() async throws {
        let fixture = try await SupervisorFixture { $0.launch.env = ["FAKE_OMP_EOF_DELAY": "1"] }
        try await fixture.supervisor.start(.fresh)
        _ = try await fixture.supervisor.command(["type": "prompt", "message": "hello"])
        try await eventually("settled") { try await fixture.entry.status == .settled }

        let started = ContinuousClock.now
        await fixture.supervisor.stop(.user)
        #expect(ContinuousClock.now - started >= .milliseconds(900))
        #expect(fixture.omp.lines("events") == ["eof"])
        let events = try await fixture.daemonEvents()
        #expect(events.contains(.exited(code: 0, signal: nil, sessionExitKind: "normal")))
        let entry = try await fixture.entry
        #expect(entry.status == .closed && entry.closedByUser)
        #expect(await !fixture.supervisor.isLive)
    }

    @Test func stragglerIsKilledAfterTheStopDeadline() async throws {
        var timings = SupervisorTimings.fastTests
        timings.stop = .milliseconds(500)
        let fixture = try await SupervisorFixture(timings: timings) { $0.launch.env = ["FAKE_OMP_EOF": "ignore"] }
        try await fixture.supervisor.start(.fresh)
        await fixture.supervisor.stop(.daemonShutdown)
        #expect(fixture.omp.lines("events") == ["eof"])
        let events = try await fixture.daemonEvents()
        #expect(events.contains(.exited(code: nil, signal: SIGKILL, sessionExitKind: nil)))
        #expect(events.contains { if case .notice("warning", let message) = $0 { message.contains("killing") } else { false } })
        // A daemon shutdown is not a user close: the session resumes with the next daemon.
        let entry = try await fixture.entry
        #expect(!entry.closedByUser && entry.status != .closed)
    }

    @Test func exitWithAnOpenPromptSynthesizesAnAbortedPromptResult() async throws {
        let fixture = try await SupervisorFixture()
        try fixture.omp.script("prompt", [#"{"type":"agent_start"}"#])
        try await fixture.supervisor.start(.fresh)
        _ = try await fixture.supervisor.command(["type": "prompt", "message": "long"])
        try await eventually("busy") { try await fixture.entry.status == .busy }
        await #expect(throws: DaemonError.self) { try await fixture.supervisor.command(["type": "crash"]) }
        try await eventually("interrupted") { try await fixture.entry.status == .interrupted }

        let promptId = try #require(fixture.omp.received.first { $0["type"] == "prompt" }?["id"])
        let records = try await fixture.records()
        let exitIndex = try #require(records.firstIndex { $0.kind == .daemon && (try? $0.payload.decode(DaemonEvent.self)) == .exited(code: 3, signal: nil, sessionExitKind: nil) })
        let synthesized = try #require(records.firstIndex { $0.kind == .omp && $0.payload["type"] == "prompt_result" })
        #expect(synthesized > exitIndex)
        #expect(records[synthesized].payload == ["type": "prompt_result", "id": promptId, "status": "aborted", "synthesized": true])
        #expect(try await fixture.daemonEvents().contains { if case .notice("error", let message) = $0 { message.contains("unexpectedly") } else { false } })
        await #expect(throws: DaemonError.self) { try await fixture.supervisor.command(["type": "get_state"]) }
    }

    @Test func pendingDialogIsTrackedThenAnsweredThroughRespond() async throws {
        let fixture = try await SupervisorFixture()
        try fixture.omp.script("prompt", [
            #"{"type":"agent_start"}"#,
            #"{"type":"extension_ui_request","id":"dlg-1","method":"confirm","title":"Continue?","message":"Really?"}"#,
            #"{"type":"extension_ui_request","id":"w-1","method":"setWidget","widgetKey":"x"}"#,
        ])
        try fixture.omp.script("answered", [
            #"{"type":"agent_end","messages":[],"isTerminal":true,"yielded":true}"#,
            #"{"type":"prompt_result","id":"__PROMPT__","agentInvoked":true,"status":"completed","sessionSettled":true}"#,
            #"{"type":"session_settled"}"#,
        ])
        try await fixture.supervisor.start(.fresh)
        _ = try await fixture.supervisor.command(["type": "prompt", "message": "ask me"])
        try await eventually("dialog pending") { try await fixture.entry.pending.uiRequests.map(\.frameId) == ["dlg-1"] }

        await #expect(throws: DaemonError.self) {
            try await fixture.supervisor.respond(requestId: "nope", response: ["confirmed": true])
        }
        try await fixture.supervisor.respond(requestId: "dlg-1", response: ["confirmed": true])
        let answer = try #require(fixture.omp.received.first { $0["type"] == "extension_ui_response" })
        #expect(answer == ["type": "extension_ui_response", "id": "dlg-1", "confirmed": true])
        #expect(try await fixture.daemonEvents().contains(.uiAnswered(requestId: "dlg-1")))
        #expect(try await fixture.entry.pending == PendingRequests())
        try await eventually("settled after the answer") { try await fixture.entry.status == .settled }
        await fixture.supervisor.stop(.user)
    }

    @Test func timedDialogLeavesPendingWhenOmpResolvesItItself() async throws {
        let fixture = try await SupervisorFixture()
        try fixture.omp.script("prompt", [
            #"{"type":"extension_ui_request","id":"t-1","method":"select","title":"Pick","options":["a","b"],"timeout":400}"#,
        ])
        try await fixture.supervisor.start(.fresh)
        _ = try await fixture.supervisor.command(["type": "prompt", "message": "pick"])
        try await eventually("dialog pending") { try await fixture.entry.pending.uiRequests.count == 1 }
        try await eventually("dialog expired", timeout: .seconds(3)) { try await fixture.entry.pending.uiRequests.isEmpty }
        await fixture.supervisor.stop(.user)
    }

    @Test func abandonedDialogsAreJournaledWhenOmpDies() async throws {
        let fixture = try await SupervisorFixture()
        try fixture.omp.script("prompt", [
            #"{"type":"extension_ui_request","id":"dlg-9","method":"input","title":"Name?"}"#,
            #"{"type":"host_tool_call","id":"host-1","toolCallId":"t","toolName":"echo_host","arguments":{}}"#,
        ])
        try await fixture.supervisor.start(.fresh)
        _ = try await fixture.supervisor.command(["type": "prompt", "message": "x"])
        try await eventually("requests pending") {
            let pending = try await fixture.entry.pending
            return pending.uiRequests.count == 1 && pending.hostToolCalls.count == 1
        }
        _ = try? await fixture.supervisor.command(["type": "crash"])
        try await eventually("interrupted") { try await fixture.entry.status == .interrupted }
        let events = try await fixture.daemonEvents()
        #expect(events.contains(.uiAbandoned(requestId: "dlg-9")) && events.contains(.uiAbandoned(requestId: "host-1")))
        #expect(try await fixture.entry.pending == PendingRequests())
    }

    @Test func hostToolCallIsAnsweredWithAHostToolResult() async throws {
        let fixture = try await SupervisorFixture()
        try fixture.omp.script("prompt", [
            #"{"type":"host_tool_call","id":"host-7","toolCallId":"t","toolName":"echo_host","arguments":{"m":"x"}}"#,
        ])
        try await fixture.supervisor.start(.fresh)
        _ = try await fixture.supervisor.command(["type": "prompt", "message": "x"])
        try await eventually("host call pending") { try await fixture.entry.pending.hostToolCalls.count == 1 }
        let result: JSONValue = ["result": ["content": [["type": "text", "text": "done"]]]]
        try await fixture.supervisor.respond(requestId: "host-7", response: result)
        let sent = try #require(fixture.omp.received.first { $0["type"] == "host_tool_result" })
        #expect(sent == ["type": "host_tool_result", "id": "host-7", "result": ["content": [["type": "text", "text": "done"]]]])
        #expect(try await fixture.entry.pending.hostToolCalls.isEmpty)
        await fixture.supervisor.stop(.user)
    }

    @Test func sessionSwitchIsRefusedWhileBusy() async throws {
        let fixture = try await SupervisorFixture()
        try fixture.omp.script("prompt", [#"{"type":"agent_start"}"#])
        try await fixture.supervisor.start(.fresh)
        _ = try await fixture.supervisor.command(["type": "prompt", "message": "long"])
        try await eventually("busy") { try await fixture.entry.status == .busy }
        for command in ["open_session", "switch_session", "new_session"] {
            await #expect(throws: DaemonError.self) { try await fixture.supervisor.command(["type": .string(command)]) }
        }
        #expect(!fixture.omp.received.contains { ["open_session", "switch_session", "new_session"].contains($0["type"]?.stringValue) })
        await fixture.supervisor.stop(.user)
    }

    @Test func bridgeEventsAreJournaledVerbatim() async throws {
        let fixture = try await SupervisorFixture(bridgeConnects: true)
        try await fixture.supervisor.start(.fresh)
        let event: JSONValue = ["t": "evt", "seq": 1, "kind": "registry:registered", "data": ["id": "Worker", "status": "running"]]
        await fixture.bridge.push(event, to: fixture.key)
        try await eventually("bridge record") {
            try await fixture.records().contains { $0.kind == .bridge && $0.payload == event }
        }
        await fixture.supervisor.stop(.user)
    }

    @Test func snapshotIsConsistentWithTheJournal() async throws {
        let fixture = try await SupervisorFixture()
        try await fixture.supervisor.start(.fresh)
        _ = try await fixture.supervisor.command(["type": "prompt", "message": "hello"])
        let snapshot = try await fixture.supervisor.snapshot()
        #expect(snapshot.state?["sessionId"] == "fake-session")
        #expect(snapshot.entries?["leafId"] == "root")
        let atSnapshot = try await fixture.records().filter { $0.seq <= snapshot.lastSeq }
        // Everything omp wrote before answering get_entries (the whole turn) is at or below lastSeq.
        #expect(atSnapshot.contains { $0.payload["type"] == "session_settled" })
        await fixture.supervisor.stop(.user)
        let stopped = try await fixture.supervisor.snapshot()
        #expect(stopped.state == nil && stopped.entries == nil)
        #expect(stopped.lastSeq == (try await fixture.records()).last?.seq)
    }

    @Test func restoreResumesTheSessionFileUnderOwnership() async throws {
        let order = Order()
        let locks = FakeLocks(onAcquire: { file in
            order.note(fakeOmpLines(nextTo: file, "argv").isEmpty ? "lock" : "lock after spawn")
        })
        let fixture = try await SupervisorFixture(locks: locks)
        let file = fixture.omp.sessionFile
        FileManager.default.createFile(atPath: file, contents: Data())
        try await fixture.manifest.updateEntry(fixture.key) { entry in
            entry.sessionFile = file
            entry.status = .busy
            entry.pending = PendingRequests(uiRequests: [["type": "extension_ui_request", "id": "old-dlg", "method": "confirm"]])
        }
        await fixture.supervisor.restoreAfterDaemonStart()

        #expect(order.values == ["lock"])
        #expect(locks.held == [file])
        #expect(fixture.omp.lines("argv").first?.hasSuffix("--resume \(file)") == true)
        let events = try await fixture.daemonEvents()
        let pid = try #require(await fixture.supervisor.pid)
        #expect(events.contains(.uiAbandoned(requestId: "old-dlg")))
        #expect(events.contains(.statusChanged(.resuming)))
        #expect(events.contains(.spawned(pid: pid, ompVersion: "18.3.1", resumed: true)))
        #expect(events.contains { if case .notice("info", let message) = $0 { message.contains("resuming") } else { false } })
        let entry = try await fixture.entry
        #expect(entry.status == .settled && entry.pending == PendingRequests())
        await fixture.supervisor.stop(.user)
    }

    @Test func resumeOfAnOwnedSessionIsRefused() async throws {
        let locks = FakeLocks()
        let fixture = try await SupervisorFixture(locks: locks)
        let file = fixture.omp.sessionFile
        FileManager.default.createFile(atPath: file, contents: Data())
        locks.holdElsewhere(file)
        try await fixture.manifest.updateEntry(fixture.key) { $0.sessionFile = file }
        await #expect(throws: DaemonError.self) { try await fixture.supervisor.start(.resume) }
        #expect(fixture.omp.lines("argv").isEmpty)
        #expect(try await fixture.entry.status == .needsAttention)
    }

    @Test func missingWorkspaceNeedsAttention() async throws {
        let fixture = try await SupervisorFixture { $0.workspace = "/nonexistent/workspace" }
        await #expect(throws: DaemonError.self) { try await fixture.supervisor.start(.fresh) }
        #expect(fixture.omp.lines("argv").isEmpty)
        #expect(try await fixture.entry.status == .needsAttention)
        #expect(try await fixture.daemonEvents().contains { if case .notice("error", let message) = $0 { message.contains("/nonexistent/workspace") } else { false } })
    }

    @Test func restoreStartsANeverSavedSessionAfresh() async throws {
        let fixture = try await SupervisorFixture()
        try await fixture.manifest.updateEntry(fixture.key) { $0.sessionFile = "/nonexistent/never-written.jsonl" }
        await fixture.supervisor.restoreAfterDaemonStart()
        #expect(fixture.omp.lines("argv").first?.contains("--resume") == false)
        #expect(try await fixture.entry.sessionFile == fixture.omp.sessionFile)
        await fixture.supervisor.stop(.user)
    }

    @Test func readOnlyModeKeepsDrainingWithoutJournaling() async throws {
        let fixture = try await SupervisorFixture()
        try await fixture.supervisor.start(.fresh)
        let journaled = try await fixture.records().count
        #expect(fixture.readOnly.trip())
        _ = try await fixture.supervisor.command(["type": "prompt", "message": "x"])
        // omp is still drained (the turn completes and the manifest follows it); nothing reaches the journal.
        try await eventually("settled in the manifest") { try await fixture.entry.lastSettledAt != nil }
        #expect(try await fixture.records().count == journaled)
        await fixture.supervisor.stop(.user)
        #expect(try await fixture.entry.status == .closed)
    }

    @Test func sessionExitKindComesFromThisRunOnly() throws {
        let temp = try ShortTempDir()
        let file = temp.url.appending(path: "s.jsonl").path(percentEncoded: false)
        let spawn = Date(timeIntervalSince1970: 1_790_000_000)
        func exit(_ kind: String, at date: Date) -> String {
            let stamp = date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
            return #"{"type":"custom","customType":"session_exit","data":{"reason":"x","kind":"\#(kind)","recordedAt":"\#(stamp)"}}"#
        }
        let aborted = #"{"type":"message","message":{"role":"toolResult","content":[{"type":"text","text":"Command aborted"}]}}"#
        try [exit("signal", at: spawn - 60), #"{"type":"message"}"#].joined(separator: "\n").appending("\n").write(toFile: file, atomically: true, encoding: .utf8)
        #expect(SessionFileTail.sessionExitKind(path: file, recordedSince: spawn) == nil)

        try [exit("signal", at: spawn - 60), exit("normal", at: spawn + 5), aborted].joined(separator: "\n").appending("\n").write(toFile: file, atomically: true, encoding: .utf8)
        #expect(SessionFileTail.sessionExitKind(path: file, recordedSince: spawn) == "normal")
        #expect(SessionFileTail.sessionExitKind(path: temp.path + "/missing.jsonl", recordedSince: spawn) == nil)
    }
}
