import Foundation
import IDEProtocol
import Testing

@testable import OmpdCore

// MARK: - Transcript lines (shapes from real omp runs)

private enum Line {
    static func stamp(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }

    static func json(_ value: JSONValue) -> String {
        String(decoding: try! JSONEncoder().encode(value), as: UTF8.self)
    }

    static func message(_ message: JSONValue, at date: Date) -> String {
        json(["type": "message", "id": .string(UUID().uuidString), "timestamp": .string(stamp(date)), "message": message])
    }

    static func custom(_ type: String, _ data: JSONValue, at date: Date) -> String {
        json(["type": "custom", "customType": .string(type), "data": data, "timestamp": .string(stamp(date))])
    }

    static func user(_ text: String, at date: Date) -> String {
        message(["role": "user", "content": [["type": "text", "text": .string(text)]]], at: date)
    }

    static func toolUse(_ id: String, command: String, at date: Date) -> String {
        message([
            "role": "assistant", "stopReason": "toolUse",
            "content": [["type": "toolCall", "id": .string(id), "name": "bash", "arguments": ["command": .string(command)]]],
        ], at: date)
    }

    /// A reply; an `aborted` one carries omp's error text (teardown: "Request was aborted"; Esc: "Interrupted by user").
    static func reply(stopReason: String = "stop", error: String? = nil, at date: Date) -> String {
        var message: [String: JSONValue] = ["role": "assistant", "stopReason": .string(stopReason), "content": [["type": "text", "text": "done"]]]
        if let error { message["errorMessage"] = .string(error) }
        return self.message(.object(message), at: date)
    }

    static func toolStart(_ id: String, tool: String = "bash", command: String, at date: Date) -> String {
        custom("tool_execution_start", [
            "toolCallId": .string(id), "toolName": .string(tool), "startedAt": .string(stamp(date)),
            "args": ["command": .string(command)],
        ], at: date)
    }

    static func toolResult(_ id: String, at date: Date) -> String {
        message(["role": "toolResult", "toolCallId": .string(id), "toolName": "bash", "content": [["type": "text", "text": "ok"]]], at: date)
    }

    static func sessionExit(pending: [(id: String, command: String)] = [], at date: Date) -> String {
        custom("session_exit", [
            "reason": "dispose", "kind": "normal", "recordedAt": .string(stamp(date)),
            "pendingToolCalls": .array(pending.map { ["toolName": "bash", "toolCallId": .string($0.id), "args": ["command": .string($0.command)]] }),
        ], at: date)
    }

    static func marker(at date: Date) -> String {
        custom(InterruptionAnalyzer.markerType, ["recordedAt": .string(stamp(date)), "decision": "continued"], at: date)
    }
}

private func write(_ lines: [String], to path: String) throws {
    try (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
}

private func append(_ lines: [String], to path: String) throws {
    let handle = try #require(FileHandle(forWritingAtPath: path))
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8))
}

// MARK: - What a dead omp left unfinished

@Suite struct InterruptionAnalyzerTests {
    let temp: ShortTempDir
    let file: String
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    init() throws {
        temp = try ShortTempDir()
        file = temp.url.appending(path: "session.jsonl").path(percentEncoded: false)
    }

    func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }

    @Test func aKillMidToolLeavesTheMainAgentInterruptedWithThatCall() throws {
        try write([
            Line.user("run it", at: at(1)), Line.toolUse("t1", command: "/bin/sleep 30", at: at(2)),
            Line.toolStart("t1", command: "/bin/sleep 30", at: at(2)),
        ], to: file)
        let found = try #require(InterruptionAnalyzer.analyze(sessionFile: file, since: at(0), cause: "crash"))
        #expect(found.mainInterrupted)
        #expect(found.pendingToolCalls == [InterruptedToolCall(toolCallId: "t1", toolName: "bash", summary: "/bin/sleep 30")])
        #expect(found.agents.isEmpty)
    }

    @Test func aFinishedTurnOrAnAbortTheUserAskedForIsNotAnInterruption() throws {
        try write([Line.user("hi", at: at(1)), Line.reply(at: at(2))], to: file)
        #expect(InterruptionAnalyzer.analyze(sessionFile: file, since: at(0), cause: "crash") == nil)
        // Esc, and a turn omp gave up on after its retries: aborted on purpose, whenever omp died.
        for error in ["Interrupted by user", "Aborted after 5 retry attempts"] {
            try write([Line.user("hi", at: at(1)), Line.reply(stopReason: "aborted", error: error, at: at(2)), Line.sessionExit(at: at(2))], to: file)
            #expect(InterruptionAnalyzer.analyze(sessionFile: file, since: at(0), cause: "crash") == nil, "\(error)")
        }
    }

    @Test func aGracefulStopMidToolReportsTheCallsOmpAbortedItself() throws {
        // EOF mid-tool: session_exit lists the call, then omp persists its "Command aborted" result.
        try write([
            Line.user("run it", at: at(1)), Line.toolUse("t1", command: "make", at: at(2)), Line.toolStart("t1", command: "make", at: at(2)),
            Line.sessionExit(pending: [("t1", "make")], at: at(3)), Line.toolResult("t1", at: at(3)),
        ], to: file)
        let found = try #require(InterruptionAnalyzer.analyze(sessionFile: file, since: at(0), cause: "ompd restarted"))
        #expect(found.mainInterrupted)
        #expect(found.pendingToolCalls.map(\.toolCallId) == ["t1"])
    }

    @Test func aReplyAbortedByTheTeardownIsAnInterruption() throws {
        // EOF mid-stream: the partial reply is persisted after session_exit.
        try write([Line.user("write", at: at(1)), Line.sessionExit(at: at(2)), Line.reply(stopReason: "aborted", error: "Request was aborted", at: at(2))], to: file)
        let found = try #require(InterruptionAnalyzer.analyze(sessionFile: file, since: at(0), cause: "ompd restarted"))
        #expect(found.mainInterrupted && found.pendingToolCalls.isEmpty)

        // SIGHUP while waiting on a subagent (chaos matrix): the exit, then the aborted `wait` result, then the aborted
        // reply, all written by the dying process.
        try write([
            Line.user("fan out", at: at(1)), Line.toolUse("w1", command: "wait", at: at(2)), Line.toolStart("w1", command: "wait", at: at(2)),
            Line.sessionExit(pending: [("w1", "wait")], at: at(3)), Line.toolResult("w1", at: at(3)),
            Line.reply(stopReason: "aborted", error: "Request was aborted", at: at(3)),
        ], to: file)
        let hungUp = try #require(InterruptionAnalyzer.analyze(sessionFile: file, since: at(0), cause: "ompd restarted"))
        #expect(hungUp.mainInterrupted && hungUp.pendingToolCalls.map(\.toolCallId) == ["w1"])
    }

    @Test func aReplyAbortedByTheTeardownIsAnInterruptionEvenWithoutASessionExit() throws {
        // Chaos matrix, SIGTERM, SIGHUP or ompd's graceful stop mid-stream: omp persists the aborted partial reply and
        // no session_exit at all.
        try write([Line.user("write", at: at(1)), Line.reply(stopReason: "aborted", error: "Request was aborted", at: at(10))], to: file)
        #expect(try #require(InterruptionAnalyzer.analyze(sessionFile: file, since: at(0), cause: "crash")).mainInterrupted)

        // A subagent disposed by the same stop: aborted result and reply first, its session_exit after them.
        try write([Line.user("write", at: at(1)), Line.reply(at: at(2))], to: file)
        let artifacts = try temp.directory("session")
        try write([
            Line.user("task", at: at(3)), Line.toolUse("s1", command: "sleep 40", at: at(4)), Line.toolStart("s1", command: "sleep 40", at: at(4)),
            Line.toolResult("s1", at: at(10)), Line.reply(stopReason: "aborted", error: "Request was aborted", at: at(10)),
            Line.sessionExit(pending: [("s1", "sleep 40")], at: at(10)),
        ], to: artifacts + "/Sleeper.jsonl")
        let found = try #require(InterruptionAnalyzer.analyze(sessionFile: file, since: at(0), cause: "ompd restarted"))
        #expect(found.agents.map(\.id) == ["Sleeper"] && found.agents.first?.pendingToolCalls.map(\.toolCallId) == ["s1"])
    }

    @Test func aHandledInterruptionIsNotReportedAgainUntilANewTurnIsCutShort() throws {
        try write([
            Line.user("run it", at: at(1)), Line.toolUse("t1", command: "a", at: at(2)), Line.toolStart("t1", command: "a", at: at(2)),
            Line.marker(at: at(5)),
        ], to: file)
        #expect(InterruptionAnalyzer.analyze(sessionFile: file, since: nil, cause: "crash") == nil)
        // The continuation prompt came after the marker and its turn died too: only the new call is pending.
        try append([Line.user("continue", at: at(6)), Line.toolUse("t2", command: "b", at: at(7)), Line.toolStart("t2", command: "b", at: at(7))], to: file)
        let found = try #require(InterruptionAnalyzer.analyze(sessionFile: file, since: nil, cause: "crash"))
        #expect(found.pendingToolCalls.map(\.toolCallId) == ["t2"])
    }

    @Test func callsFromBeforeTheDeadRunStartedAreNotItsOwn() throws {
        try write([
            Line.user("old", at: at(1)), Line.toolUse("old", command: "a", at: at(2)), Line.toolStart("old", command: "a", at: at(2)),
            Line.user("new", at: at(10)), Line.toolUse("new", command: "b", at: at(11)), Line.toolStart("new", command: "b", at: at(11)),
        ], to: file)
        let found = try #require(InterruptionAnalyzer.analyze(sessionFile: file, since: at(9), cause: "crash"))
        #expect(found.pendingToolCalls.map(\.toolCallId) == ["new"])
    }

    @Test func onlyUnfinishedSubagentsOfTheDeadRunAreInterrupted() throws {
        try write([Line.user("fan out", at: at(1)), Line.reply(at: at(2))], to: file)
        let artifacts = try temp.directory("session")
        func agent(_ id: String, _ lines: [String], output: String? = nil, tombstone: Bool = false, modified: Date? = nil) throws {
            let path = artifacts + "/" + id + ".jsonl"
            try write(lines, to: path)
            if let output { try output.write(toFile: artifacts + "/" + id + ".md", atomically: true, encoding: .utf8) }
            if tombstone { FileManager.default.createFile(atPath: path + ".tombstone", contents: nil) }
            if let modified { try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: path) }
        }
        let midTool = [Line.user("task", at: at(3)), Line.toolUse("s1", command: "sleep 30", at: at(4)), Line.toolStart("s1", command: "sleep 30", at: at(4))]
        try agent("Sleeper", midTool)
        try agent("Finished", midTool, output: "{\"output\":\"ok\"}")
        try agent("Killed", midTool, output: "", tombstone: true)
        try agent("Stale", midTool, modified: at(-100))
        try agent("Idle", [Line.user("task", at: at(3)), Line.reply(at: at(4))])

        let found = try #require(InterruptionAnalyzer.analyze(sessionFile: file, since: at(0), cause: "crash"))
        #expect(!found.mainInterrupted)
        #expect(found.agents == [InterruptedAgent(id: "Sleeper", pendingToolCalls: [
            InterruptedToolCall(toolCallId: "s1", toolName: "bash", summary: "sleep 30"),
        ])])
    }

    @Test func evalInTheDeadRunMeansItsKernelsAreLost() throws {
        try write([
            Line.user("compute", at: at(1)), Line.toolUse("e1", command: "x", at: at(2)), Line.toolStart("e1", tool: "eval", command: "x", at: at(2)),
        ], to: file)
        #expect(try #require(InterruptionAnalyzer.analyze(sessionFile: file, since: at(0), cause: "crash")).evalKernelsLost)
        #expect(try #require(InterruptionAnalyzer.analyze(sessionFile: file, since: at(5), cause: "crash")).evalKernelsLost == false)
    }
}

// MARK: - Continuation after a respawn

private let recoveryCapabilities: [String: Bool] = [
    "session.prompt": true, "agent.message": true, "entry.append": true, "agents.loadPersisted": true, "session.watchStall": true,
]

@Suite(.timeLimit(.minutes(1)))
struct RecoveryTests {
    /// Starts the session, then writes an interrupted main turn (a bash call in flight) and, with `agent`, an
    /// interrupted subagent into its files; returns the session file.
    private func interruptedSession(_ fixture: SupervisorFixture, agent: Bool = false) async throws -> String {
        try await fixture.supervisor.start(.fresh)
        try await fixture.waitForStatus(.idle)
        let file = try #require(try await fixture.entry.sessionFile)
        let now = Date()
        try append([Line.user("deploy", at: now), Line.toolUse("t1", command: "./deploy.sh", at: now), Line.toolStart("t1", command: "./deploy.sh", at: now)], to: file)
        if agent {
            let artifacts = String(file.dropLast(".jsonl".count))
            try FileManager.default.createDirectory(atPath: artifacts, withIntermediateDirectories: true)
            try write([Line.user("task", at: now), Line.toolUse("s1", command: "sleep 30", at: now), Line.toolStart("s1", command: "sleep 30", at: now)], to: artifacts + "/Sleeper.jsonl")
        }
        return file
    }

    private func crashAndWaitForResume(_ fixture: SupervisorFixture) async throws {
        let old = try await fixture.pty().ptyId
        try await fixture.type("crash")
        try await eventually("respawn") {
            let entry = try await fixture.entry
            return entry.status == .idle && entry.ptyId != old
        }
    }

    private func requests(_ fixture: SupervisorFixture, _ method: String) async -> [JSONValue] {
        await fixture.bridge.requests.filter { $0.method == method }.map(\.params)
    }

    @Test func autoContinuesSubagentsFirstThenTheMainAgentAndOnlyOnce() async throws {
        let fixture = try await SupervisorFixture(bridgeCapabilities: recoveryCapabilities, restorePolicy: RestorePolicy(main: .auto, subagents: .auto))
        _ = try await interruptedSession(fixture, agent: true)
        try await crashAndWaitForResume(fixture)
        try await eventually("continuation prompt") { await !requests(fixture, "session.prompt").isEmpty }

        let order = await fixture.bridge.calls.filter { ["agents.loadPersisted", "entry.append", "agent.message", "session.prompt"].contains($0) }
        #expect(order == ["agents.loadPersisted", "entry.append", "agent.message", "session.prompt"])
        let message = try #require(await requests(fixture, "agent.message").first)
        #expect(message["id"] == "Sleeper")
        #expect(message["body"]?.stringValue?.contains("sleep 30") == true)
        let prompt = try #require(await requests(fixture, "session.prompt").first?["text"]?.stringValue)
        #expect(prompt.contains("- bash: ./deploy.sh"))
        #expect(prompt.contains("asked to continue") && prompt.contains("Sleeper"))
        #expect(try await fixture.entry.pendingContinuation == nil)

        // The marker went into the file: the same interruption is not continued again at the next death.
        try await crashAndWaitForResume(fixture)
        try await Task.sleep(for: .milliseconds(300))
        #expect(await requests(fixture, "session.prompt").count == 1)
        await fixture.finish()
    }

    @Test func askHoldsTheInterruptionUntilTheUserAnswers() async throws {
        let fixture = try await SupervisorFixture(bridgeCapabilities: recoveryCapabilities, restorePolicy: RestorePolicy(main: .ask, subagents: .ask))
        _ = try await interruptedSession(fixture, agent: true)
        try await crashAndWaitForResume(fixture)
        let pending = try await eventuallyValue("pending continuation") { try await fixture.entry.pendingContinuation }
        #expect(pending.mainInterrupted && pending.pendingToolCalls.map(\.toolCallId) == ["t1"])
        #expect(pending.agents.map(\.id) == ["Sleeper"])
        #expect(await requests(fixture, "session.prompt").isEmpty)
        #expect(await requests(fixture, "agent.message").isEmpty)

        // Only the subagent: it is messaged, the main agent is left (and recorded as left), nothing stays pending.
        try await fixture.supervisor.continueInterrupted(main: false, agents: ["Sleeper"])
        #expect(await requests(fixture, "agent.message").map { $0["id"] } == ["Sleeper"])
        #expect(await requests(fixture, "session.prompt").isEmpty)
        let decisions = await requests(fixture, "entry.append").compactMap { $0["data"]?["decision"]?.stringValue }
        #expect(decisions == ["left", "continued"])
        #expect(try await fixture.entry.pendingContinuation == nil)
        await #expect(throws: DaemonError.self) { try await fixture.supervisor.continueInterrupted(main: true, agents: []) }
        await fixture.finish()
    }

    @Test func neverLeavesTheInterruptionAndRecordsThat() async throws {
        let fixture = try await SupervisorFixture(bridgeCapabilities: recoveryCapabilities, restorePolicy: RestorePolicy(main: .never, subagents: .never))
        _ = try await interruptedSession(fixture)
        try await crashAndWaitForResume(fixture)
        try await eventually("marker") { await !requests(fixture, "entry.append").isEmpty }
        #expect(await requests(fixture, "entry.append").first?["data"]?["decision"] == "left")
        #expect(await requests(fixture, "session.prompt").isEmpty)
        #expect(try await fixture.entry.pendingContinuation == nil)
        await fixture.finish()
    }

    @Test func aDaemonRestartContinuesFromTheRecordedRunStart() async throws {
        // The previous daemon's omp served the file since `spawnedAt`; a call from an earlier run is not reported.
        let spawned = Date().addingTimeInterval(-60)
        let fixture = try await SupervisorFixture(
            bridgeCapabilities: recoveryCapabilities, restorePolicy: RestorePolicy(main: .auto, subagents: .auto))
        let file = fixture.omp.directory.appending(path: "old-session.jsonl").path(percentEncoded: false)
        try write([
            Line.user("old", at: spawned.addingTimeInterval(-30)), Line.toolUse("old", command: "old.sh", at: spawned.addingTimeInterval(-30)),
            Line.toolStart("old", command: "old.sh", at: spawned.addingTimeInterval(-30)),
            Line.user("new", at: spawned.addingTimeInterval(10)), Line.toolUse("new", command: "new.sh", at: spawned.addingTimeInterval(10)),
            Line.toolStart("new", command: "new.sh", at: spawned.addingTimeInterval(10)),
        ], to: file)
        try await fixture.manifest.updateEntry(fixture.key) { entry in
            entry.sessionFile = file
            entry.spawnedAt = spawned
            entry.status = .interrupted
        }
        await fixture.supervisor.restoreAfterDaemonStart()
        let prompt = try await eventuallyValue("continuation prompt") { await requests(fixture, "session.prompt").first?["text"]?.stringValue }
        #expect(prompt.contains("new.sh") && prompt.contains("ompd restarted"))
        #expect(!prompt.contains("old.sh"))
        await fixture.finish()
    }

    @Test func servicesThatShouldRunAreRelaunchedAndLostOnesReported() async throws {
        let services = FakeServices(states: ["web": "exited", "live": "ready", "gone-too": "failed"], outcomes: ["gone-too": .unknown])
        let fixture = try await SupervisorFixture(bridgeCapabilities: recoveryCapabilities, services: services)
        try await fixture.supervisor.start(.fresh)
        try await fixture.waitForStatus(.idle)
        for name in ["web", "live", "db", "gone-too", "stopped"] {
            await fixture.bridge.push("service", ["op": "started", "name": .string(name), "command": .string("run \(name)")], to: fixture.key)
        }
        await fixture.bridge.push("service", ["op": "stopped", "name": "stopped"], to: fixture.key)
        await fixture.bridge.push("service", ["op": "mode", "name": "web", "mode": "persist"], to: fixture.key)
        try await eventually("services recorded") {
            let services = try await fixture.entry.services
            return services.count == 5 && services.first { $0.id == "stopped" }?.desiredRunning == false
                && services.first { $0.id == "web" }?.mode == "persist"
        }

        try await crashAndWaitForResume(fixture)
        try await eventually("lost services recorded") {
            try await fixture.entry.services.filter(\.desiredRunning).map(\.id).sorted() == ["live", "web"]
        }
        // Running ones are left alone, a stopped one stays stopped, one the broker never knew is not tried.
        #expect(services.restarts.value.sorted() == ["gone-too", "web"])
        let messages = fixture.notices.value.map(\.message)
        #expect(messages.contains { $0.contains("Restarted the named service web") })
        #expect(messages.contains { $0.contains("db was not restored") && $0.contains("run db") })
        #expect(messages.contains { $0.contains("gone-too was not restored") })
        await fixture.finish()
    }

    @Test func aStalledTurnAfterAWakeIsAbortedAndContinued() async throws {
        let fixture = try await SupervisorFixture(bridgeCapabilities: recoveryCapabilities)
        try await fixture.supervisor.start(.fresh)
        try await fixture.waitForStatus(.idle)
        await fixture.supervisor.healthCheck()
        #expect(await !fixture.bridge.calls.contains("session.watchStall"), "an idle agent is not watched")

        await fixture.bridge.push("activity", ["state": "busy"], to: fixture.key)
        try await fixture.waitForStatus(.busy)
        await fixture.supervisor.healthCheck()
        #expect(await requests(fixture, "session.prompt").first?["text"]?.stringValue == ContinuationMessages.wake)
        await fixture.finish()
    }
}
