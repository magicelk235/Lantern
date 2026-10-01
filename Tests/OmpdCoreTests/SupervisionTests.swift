import Foundation
import IDEProtocol
import IDETransport
import Testing

@testable import OmpdCore

/// A registry row as the ide-bridge sends it (`refJson`; times in ms since the epoch).
private func row(
    _ id: String, parent: String? = nil, status: String = "running", kind: String = "sub", createdAt: Double = 0,
    activity: JSONValue = .null, currentTool: JSONValue = .null
) -> JSONValue {
    [
        "id": .string(id), "displayName": .string(id), "kind": .string(kind), "parentId": parent.map { .string($0) } ?? .null,
        "status": .string(status), "hasSession": true, "isStreaming": false, "sessionFile": .null, "createdAt": .number(createdAt),
        "lastActivity": .number(createdAt), "activity": activity, "currentTool": currentTool, "lifecycle": .null, "history": .null,
    ]
}

private func at(milliseconds: Double) -> Date { Date(timeIntervalSince1970: milliseconds / 1000) }

// MARK: - Folding the bridge's pushes

@Suite struct RuntimeTrackerTests {
    @Test func registryPushesFoldIntoATreeWithParentsBeforeTheirChildren() throws {
        var tracker = RuntimeTracker()
        tracker.seed(agents: [row("Main", kind: "main", createdAt: 1_000)])
        // A child's row can come before its parent's; it is still listed after it.
        tracker.apply(registry: "registered", row: row("0-Explore.1-Check", parent: "0-Explore", createdAt: 4_000))
        tracker.apply(registry: "registered", row: row("1-Later", parent: "Main", createdAt: 5_000))
        tracker.apply(registry: "registered", row: row("0-Explore", parent: "Main", createdAt: 3_000, activity: "running  bash\n tests"))
        tracker.apply(registry: "registered", row: row("Main/advisor", parent: "Main", status: "parked", kind: "advisor", createdAt: 2_000))
        var runtime = tracker.runtime(sessionKey: "s", mainStatus: .idle, held: [])
        #expect(runtime.agents.map(\.id) == ["Main", "Main/advisor", "0-Explore", "0-Explore.1-Check", "1-Later"])
        let explore = try #require(runtime.agents.first { $0.id == "0-Explore" })
        #expect(explore == AgentInfo(
            id: "0-Explore", displayName: "0-Explore", kind: "sub", parentId: "Main", status: .running,
            createdAt: at(milliseconds: 3_000), lastActivity: at(milliseconds: 3_000), activity: "running bash tests"))

        tracker.apply(registry: "status_changed", row: row("0-Explore", parent: "Main", status: "idle", createdAt: 3_000))
        tracker.apply(registry: "removed", row: row("1-Later", parent: "Main", createdAt: 5_000))
        tracker.apply(registry: "removed", row: row("Never-Listed", parent: "Main"))
        tracker.apply(registry: "renamed", row: row("0-Explore", parent: "Main", status: "aborted"))
        tracker.apply(registry: "registered", row: ["id": "no-status"])
        tracker.apply(registry: "registered", row: row("Odd", parent: "Main", status: "hibernating", createdAt: 6_000))
        runtime = tracker.runtime(sessionKey: "s", mainStatus: .idle, held: [])
        #expect(runtime.agents.map(\.id) == ["Main", "Main/advisor", "0-Explore", "0-Explore.1-Check", "Odd"])
        #expect(runtime.agents.map(\.status) == [.idle, .parked, .idle, .running, .unknown])

        // A row whose parent is not listed is a root, after the main agent.
        tracker.seed(agents: [row("Orphan", parent: "Gone", createdAt: 1), row("Main", kind: "main", createdAt: 2)])
        #expect(tracker.runtime(sessionKey: "s", mainStatus: .idle, held: []).agents.map(\.id) == ["Main", "Orphan"])
    }

    @Test func activityIsOmpsIntentElseTheToolCallTheAgentRuns() {
        let sleeping: JSONValue = ["name": "bash", "detail": "sleep  25\n"]
        func activity(_ omp: JSONValue, _ currentTool: JSONValue = .null) -> String? {
            RuntimeTracker.agent(row("0-Scout", parent: "Main", activity: omp, currentTool: currentTool))?.activity
        }
        // The intent the model gave the subagent's tool call comes first.
        #expect(activity("Wait for the  build", sleeping) == "Wait for the build")
        // omp's bare `running <tool>` gives way to the call the bridge saw start, with what it works on.
        #expect(activity("running bash", sleeping) == "bash: sleep 25")
        #expect(activity("running bash") == "bash")
        // Without omp's field (the main agent, or before omp updated it): the call itself.
        #expect(activity(.null, sleeping) == "bash: sleep 25")
        #expect(activity("  ", ["name": "todo", "detail": .null]) == "todo")
        #expect(activity(.null) == nil)
        #expect(activity(["text": "not a line"]) == nil)
    }

    @Test func theMainAgentFollowsTheSessionAndHeldParkedSubagentsReadInterrupted() {
        var tracker = RuntimeTracker()
        tracker.seed(agents: [
            row("Main", kind: "main"), row("Sleeper", parent: "Main", status: "parked", createdAt: 1),
            row("Left", parent: "Main", status: "parked", createdAt: 2), row("Busy", parent: "Main", createdAt: 3),
        ])
        func statuses(_ session: SessionStatus, held: Set<String> = []) -> [String: AgentStatus] {
            let runtime = tracker.runtime(sessionKey: "s", mainStatus: RuntimeTracker.mainStatus(session), held: held)
            return Dictionary(uniqueKeysWithValues: runtime.agents.map { ($0.id, $0.status) })
        }
        // omp reports the main agent `running` for its whole life; the session says what it does.
        #expect(statuses(.idle)["Main"] == .idle)
        #expect(statuses(.busy)["Main"] == .running)
        #expect(statuses(.paused)["Main"] == .paused)
        #expect(statuses(.resuming)["Main"] == .idle)
        #expect(statuses(.idle, held: ["Sleeper", "Busy"]) == ["Main": .idle, "Sleeper": .interrupted, "Left": .parked, "Busy": .running])
    }

    @Test func jobsAndAttentionAreReplacedWhole() {
        var tracker = RuntimeTracker()
        tracker.replaceJobs([
            "running": [["id": "bg-1", "type": "bash", "status": "running", "label": "sleep 30", "startTime": 1_000]],
            "recent": [[
                "id": "task-1", "type": "task", "status": "completed", "label": "Explore", "startTime": 500, "endTime": 900,
                "agentId": "0-Explore",
            ]],
        ])
        #expect(tracker.jobs == [
            JobInfo(id: "bg-1", type: "bash", status: "running", label: "sleep 30", startedAt: at(milliseconds: 1_000)),
            JobInfo(
                id: "task-1", type: "task", status: "completed", label: "Explore", startedAt: at(milliseconds: 500),
                endedAt: at(milliseconds: 900), agentId: "0-Explore"),
        ])
        tracker.replaceJobs(["running": [], "recent": [["id": "bg-1", "type": "bash", "status": "completed", "label": "sleep 30"]]])
        #expect(tracker.jobs.map(\.id) == ["bg-1"] && tracker.jobs.first?.isRunning == false)

        tracker.attention = RuntimeTracker.attention([
            ["id": "call-1", "kind": "approval", "toolName": "bash", "agentId": "Main", "since": 2_000],
            ["id": "call-2", "kind": "ask", "toolName": "ask", "agentId": "0-Explore", "since": 3_000],
            ["id": "call-3", "kind": "dialog", "toolName": "select", "since": 4_000],
            ["kind": "ask", "toolName": "ask", "since": 5_000],
        ])
        #expect(tracker.attention == [
            AttentionItem(id: "call-1", kind: .approval, toolName: "bash", agentId: "Main", since: at(milliseconds: 2_000)),
            AttentionItem(id: "call-2", kind: .ask, toolName: "ask", agentId: "0-Explore", since: at(milliseconds: 3_000)),
        ])
        tracker.attention = RuntimeTracker.attention([["id": "call-2", "kind": "ask", "toolName": "ask", "since": 3_000]])
        #expect(tracker.runtime(sessionKey: "s", mainStatus: .idle, held: []).attention.map(\.id) == ["call-2"])
    }
}

// MARK: - A session's runtime

private let supervisionCapabilities: [String: Bool] = [
    "agents.snapshot": true, "events.registry": true, "events.attention": true, "events.jobs": true, "agent.revive": true,
    "agent.kill": true, "agent.message": true, "entry.append": true,
]

/// What a `SessionSupervisor` delivers as `runtime` and does for `agent.control`/`agent.message`, over the fake omp with
/// a scripted bridge.
@Suite(.timeLimit(.minutes(2)))
struct SupervisionTests {
    /// The last runtime delivered that satisfies `condition`.
    private func runtime(_ fixture: SupervisorFixture, _ what: String, where condition: @escaping @Sendable (SessionRuntime) -> Bool)
        async throws -> SessionRuntime
    {
        try await eventuallyValue(what) { fixture.runtimes.value.last.flatMap { condition($0) ? $0 : nil } }
    }

    @Test func theRuntimeFollowsTheBridgeAndIsEmptiedWhenOmpStops() async throws {
        let fixture = try await SupervisorFixture(bridgeCapabilities: supervisionCapabilities)
        await fixture.bridge.setAgents([row("Main", kind: "main")])
        try await fixture.supervisor.start(.fresh)
        let seeded = try await runtime(fixture, "the runtime seeded from agents.snapshot") { !$0.agents.isEmpty }
        let main = AgentInfo(
            id: "Main", displayName: "Main", kind: "main", status: .idle, createdAt: at(milliseconds: 0), lastActivity: at(milliseconds: 0))
        #expect(seeded == SessionRuntime(sessionKey: fixture.key, agents: [main]))

        await fixture.bridge.push("registry:registered", row("0-Scout", parent: "Main", createdAt: 10), to: fixture.key, agentId: "0-Scout")
        await fixture.bridge.push("activity", ["state": "busy"], to: fixture.key)
        await fixture.bridge.push(
            "jobs", ["running": [["id": "bg-1", "type": "bash", "status": "running", "label": "sleep 30"]], "recent": []], to: fixture.key)
        await fixture.bridge.push(
            "attention", ["items": [["id": "call-1", "kind": "approval", "toolName": "bash", "agentId": "Main", "since": 1_000]]],
            to: fixture.key)
        let busy = try await runtime(fixture, "the pushed runtime") { $0.attention.count == 1 }
        #expect(busy.agents.map(\.id) == ["Main", "0-Scout"] && busy.agents.map(\.status) == [.running, .running])
        #expect(busy.jobs.map(\.id) == ["bg-1"])
        #expect(await fixture.supervisor.runtime == busy)
        let delivered = fixture.runtimes.value
        #expect(zip(delivered, delivered.dropFirst()).allSatisfy { $0 != $1 }, "only changes are delivered")

        // A crash: emptied, then seeded again from the respawned omp's bridge.
        let before = fixture.runtimes.value.count
        try await fixture.type("crash")
        let reseeded = try await runtime(fixture, "the respawned omp's runtime") { $0.agents.map(\.id) == ["Main"] }
        #expect(fixture.runtimes.value[before...].contains(SessionRuntime(sessionKey: fixture.key)))
        #expect(reseeded.jobs.isEmpty && reseeded.attention.isEmpty)

        // omp quits: emptied for good.
        try await fixture.waitForStatus(.idle)
        try await fixture.type("exit")
        try await fixture.waitForStatus(.closed)
        #expect(fixture.runtimes.value.last == SessionRuntime(sessionKey: fixture.key))
        #expect(await fixture.supervisor.runtime == SessionRuntime(sessionKey: fixture.key))
        await fixture.finish()
    }

    @Test func agentControlGoesThroughTheBridgeAndMapsItsFailures() async throws {
        let fixture = try await SupervisorFixture(bridgeCapabilities: supervisionCapabilities)
        let notRunning = await #expect(throws: DaemonError.self) { try await fixture.supervisor.control(agent: "0-Scout", .kill) }
        #expect(notRunning?.code == .bridgeUnavailable)

        await fixture.bridge.setAgents([row("Main", kind: "main"), row("0-Scout", parent: "Main", status: "parked")])
        try await fixture.supervisor.start(.fresh)
        _ = try await runtime(fixture, "the seeded runtime") { !$0.agents.isEmpty }
        // Reviving the main agent asks omp nothing: it is there, as the session shows it.
        let main = try await fixture.supervisor.control(agent: "Main", .revive)
        #expect(main?.id == "Main" && main?.status == .idle)
        #expect(await !fixture.bridge.calls.contains("agent.revive"))

        let killed = try await fixture.supervisor.control(agent: "0-Scout", .kill)
        #expect(killed?.id == "0-Scout" && killed?.status == .parked)
        let kill = try #require(await fixture.bridge.requests.last)
        #expect(kill.method == "agent.kill" && kill.params == ["id": "0-Scout"])
        try await fixture.supervisor.message(agent: "0-Scout", body: "carry on")
        let message = try #require(await fixture.bridge.requests.last)
        #expect(message.method == "agent.message" && message.params == ["id": "0-Scout", "body": "carry on"])

        let cannotPark = await #expect(throws: DaemonError.self) { try await fixture.supervisor.control(agent: "0-Scout", .park) }
        #expect(cannotPark?.code == .bridgeUnavailable, "the bridge lacks agent.park")
        await fixture.bridge.refuse("agent.revive", with: "unknown agent: Ghost")
        let refused = await #expect(throws: DaemonError.self) { try await fixture.supervisor.control(agent: "Ghost", .revive) }
        #expect(refused == DaemonError(.ompError, "unknown agent: Ghost"))
        await fixture.finish()
    }

    @Test func aParkedSubagentOfAnInterruptionWaitingForTheUserReadsInterruptedUntilAnswered() async throws {
        let fixture = try await SupervisorFixture(bridgeCapabilities: supervisionCapabilities) { entry in
            entry.pendingContinuation = Interruption(
                detectedAt: Date(), cause: "omp exited unexpectedly", mainInterrupted: false, agents: [InterruptedAgent(id: "Sleeper")])
        }
        await fixture.bridge.setAgents([row("Main", kind: "main"), row("Sleeper", parent: "Main", status: "parked", createdAt: 1)])
        try await fixture.supervisor.start(.fresh)
        let held = try await runtime(fixture, "the seeded runtime") { !$0.agents.isEmpty }
        #expect(held.agents.map(\.status) == [.idle, .interrupted])
        // The user leaves it: a parked subagent like any other.
        try await fixture.supervisor.continueInterrupted(main: false, agents: [])
        #expect(fixture.runtimes.value.last?.agents.map(\.status) == [.idle, .parked])
        await fixture.finish()
    }
}

// MARK: - Through the daemon

/// Agent supervision through the daemon's socket: runtime pushes and `session.runtime`, agent requests routed to their
/// session, and named services merged from omp's broker and the manifest and controlled through `omp ps` and the bridge.
@Suite(.timeLimit(.minutes(2)))
struct DaemonSupervisionTests {
    @Test func runtimesReachClientsAndAgentRequestsReachTheirSession() async throws {
        let fixture = try await DaemonFixture(capabilities: supervisionCapabilities)
        let connected = try await fixture.client()
        let client = connected.client
        await fixture.bridge.setAgents([row("Main", kind: "main")])
        let entry = try await fixture.createSession(connected)
        let key = entry.sessionKey
        try await connected.waitForStatus(key, .idle)
        await fixture.bridge.push("registry:registered", row("0-Scout", parent: "Main"), to: key, agentId: "0-Scout")
        let pushed = try await eventuallyValue("a runtime push with the subagent") {
            connected.pushes.lazy.compactMap { if case .runtime(let runtime) = $0, runtime.agents.count == 2 { runtime } else { nil } }.first
        }
        #expect(pushed.sessionKey == key && pushed.agents.map(\.id) == ["Main", "0-Scout"])
        #expect(try await client.call(SessionRuntimeList.self, Empty()).sessions == [pushed])

        _ = try await client.call(AgentMessage.self, .init(sessionKey: key, agentId: "0-Scout", body: "status?"))
        #expect(await fixture.bridge.requests.last { $0.method == "agent.message" }?.params == ["id": "0-Scout", "body": "status?"])
        let killed = try await client.call(AgentControl.self, .init(sessionKey: key, agentId: "0-Scout", action: .kill)).agent
        #expect(killed == nil, "omp no longer lists it")
        let unknown = await #expect(throws: DaemonError.self) {
            try await client.call(AgentControl.self, .init(sessionKey: "no-such-session", agentId: "Main", action: .revive))
        }
        #expect(unknown?.code == .noSuchSession)

        _ = try await client.call(SessionClose.self, .init(sessionKey: key))
        try await eventually("the emptied runtime pushed") {
            connected.pushes.last { if case .runtime = $0 { true } else { false } } == .runtime(SessionRuntime(sessionKey: key))
        }
        #expect(try await client.call(SessionRuntimeList.self, Empty()).sessions == [SessionRuntime(sessionKey: key)])
        await connected.close()
        await fixture.daemon.shutdown()
    }

    @Test func servicesMergeTheBrokerWithWhatSessionsRecordedAndAreControlled() async throws {
        let started = Date(timeIntervalSince1970: 1_790_000_000)
        let services = FakeServices(
            records: [
                ServiceRecord(
                    name: "web", state: "ready", mode: "persist", pid: 4242, command: "/bin/zsh -l -c run web", startedAt: started,
                    owner: "fake-session"),
                ServiceRecord(name: "stray", state: "ready", supervised: false, mode: "session", command: "/bin/zsh -l -c sleep 9"),
            ],
            outcomes: ["gone": .unknown])
        let fixture = try await DaemonFixture(capabilities: ["service.mode": true], services: services)
        let connected = try await fixture.client()
        let client = connected.client
        let entry = try await fixture.createSession(connected)
        let key = entry.sessionKey
        try await connected.waitForStatus(key, .idle)
        for name in ["web", "gone"] {
            await fixture.bridge.push("service", ["op": "started", "name": .string(name), "command": .string("run \(name)")], to: key)
        }
        try await eventually("services recorded") { try await connected.entry(key).services.count == 2 }

        let listed = try await client.call(ServiceList.self, .init(workspace: fixture.workspace)).services
        #expect(listed == [
            ServiceInfo(name: "gone", state: "unknown", mode: "session", command: "run gone", sessionKey: key, desiredRunning: true),
            ServiceInfo(name: "stray", state: "unsupervised", mode: "session", command: "/bin/zsh -l -c sleep 9"),
            ServiceInfo(
                name: "web", state: "ready", mode: "persist", command: "run web", pid: 4242, startedAt: started, sessionKey: key,
                desiredRunning: true),
        ])
        // `omp ps` ran for the canonical workspace, with the session's pinned omp.
        #expect(services.invocations.value.last?.workspace == entry.workspace)
        #expect(services.invocations.value.last?.omp == entry.launch.ompPath)

        func control(_ name: String, _ action: ServiceControlRequest.Action, mode: String? = nil) async throws -> ServiceInfo {
            try await client.call(ServiceControlRequest.self, .init(workspace: fixture.workspace, name: name, action: action, mode: mode)).service
        }
        func desired(_ name: String) async throws -> Bool? {
            try await connected.entry(key).services.first { $0.id == name }?.desiredRunning
        }
        #expect(try await control("web", .stop).desiredRunning == false)
        #expect(try await desired("web") == false)
        #expect(try await control("web", .restart).desiredRunning == true)
        // The broker forgot it: nothing runs under that name, so a kill leaves it stopped; a restart has nothing to go on.
        #expect(try await control("gone", .kill).state == "unknown")
        #expect(try await desired("gone") == false)
        let lost = await #expect(throws: DaemonError.self) { try await control("gone", .restart) }
        #expect(lost?.code == .ompError)
        #expect(services.commands.value == ["stop web", "restart web", "kill gone", "restart gone"])

        // A mode change goes through the session's bridge, and is recorded.
        _ = try await control("web", .setMode, mode: "detached")
        #expect(await fixture.bridge.requests.last { $0.method == "service.mode" }?.params == ["name": "web", "mode": "detached"])
        let web = try #require(try await connected.entry(key).services.first { $0.id == "web" })
        #expect(web.mode == "detached" && !web.pty)
        let badMode = await #expect(throws: DaemonError.self) { try await control("web", .setMode, mode: "forever") }
        #expect(badMode?.code == .badParams)
        _ = try await client.call(SessionClose.self, .init(sessionKey: key))
        let noBridge = await #expect(throws: DaemonError.self) { try await control("web", .setMode, mode: "persist") }
        #expect(noBridge?.code == .bridgeUnavailable, "no omp of the workspace runs")
        await connected.close()
        await fixture.daemon.shutdown()
    }
}
