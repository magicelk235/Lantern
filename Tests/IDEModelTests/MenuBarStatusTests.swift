import Foundation
@testable import IDEModel
import Testing

@Suite struct MenuBarStatusTests {
    /// The menu bar counts what works now: a busy session's main agent and the subagents omp reports running. An idle
    /// main agent, idle or parked subagents, and every agent of a paused session (held at omp's pause gate) do not count.
    @Test func countsTheAgentsThatWorkRightNow() {
        let sessions = [
            manifestEntry("busy", status: .busy), manifestEntry("idle", status: .idle), manifestEntry("paused", status: .paused),
        ]
        let runtimes = [
            "busy": SessionRuntime(sessionKey: "busy", agents: [
                main(.running), agent("0-Explore", .running), agent("1-Check", .idle), agent("2-Old", .parked),
                agent("0-Explore.0-Deep", .running, parent: "0-Explore"),
            ]),
            "idle": SessionRuntime(sessionKey: "idle", agents: [main(.idle), agent("0-Background", .running)]),
            "paused": SessionRuntime(sessionKey: "paused", agents: [main(.paused), agent("0-Held", .running)]),
        ]
        let status = MenuBarStatus(sessions: sessions, runtimes: runtimes)
        #expect(status.runningAgents == 4)
        #expect(status.projects.flatMap(\.sessions).map(\.runningAgents) == [3, 1, 0])
    }

    /// A busy session counts its main agent even when ompd reports none of its agents (a bridge that cannot list them).
    @Test func aBusySessionCountsItsMainAgentWithoutAnAgentList() {
        let status = MenuBarStatus(sessions: [manifestEntry("a", status: .busy)], runtimes: [:])
        #expect(status.runningAgents == 1)
    }

    /// Nothing works in a session that is paused or whose omp does not run, whatever ompd last listed for it.
    @Test(arguments: [SessionStatus.paused, .starting, .resuming, .interrupted, .needsAttention, .closed])
    func aSessionThatIsHeldOrNotRunningCountsNone(status: SessionStatus) {
        let runtime = SessionRuntime(sessionKey: "a", agents: [main(.running), agent("0-Task", .running)])
        #expect(MenuBarStatus.runningAgents(of: manifestEntry("a", status: status), runtime: runtime) == 0)
    }

    /// Every approval and ask counts, in paused sessions too (omp's prompt stays open under the pause); a session shows
    /// the oldest that waits in it.
    @Test func approvalsAndAsksWaitingInAnySession() {
        let approval = AttentionItem(id: "call-1", kind: .approval, toolName: "bash", agentId: "Main", since: testDate)
        let ask = AttentionItem(id: "call-2", kind: .ask, toolName: "ask", since: testDate.addingTimeInterval(5))
        let elsewhere = AttentionItem(id: "call-3", kind: .ask, toolName: "ask", since: testDate)
        let status = MenuBarStatus(
            sessions: [manifestEntry("a", status: .paused), manifestEntry("b", status: .idle), manifestEntry("c", status: .idle)],
            runtimes: [
                "a": SessionRuntime(sessionKey: "a", attention: [approval, ask]),
                "b": SessionRuntime(sessionKey: "b", attention: [elsewhere]),
            ])
        #expect(status.waitingCount == 3)
        #expect(status.projects.flatMap(\.sessions).map(\.waiting) == [approval, elsewhere, nil])
        #expect(approval.waitingLine == "Waiting for approval: bash")
        #expect(ask.waitingLine == "Asking you")
    }

    /// Sessions are listed under their project folder, projects by name, each project's sessions oldest first (the
    /// order of its tabs). Closed sessions are not listed; an untitled session is "New session".
    @Test func sessionsAreListedByProject() {
        var older = manifestEntry("older", workspace: "/Users/me/zeta", status: .idle)
        older.title = "Fix the login bug"
        var newer = manifestEntry("newer", workspace: "/Users/me/zeta", status: .needsAttention)
        newer.createdAt = testDate.addingTimeInterval(60)
        newer.title = ""
        var alpha = manifestEntry("alpha", workspace: "/tmp/Alpha", status: .starting)
        alpha.createdAt = testDate.addingTimeInterval(120)
        let closed = manifestEntry("closed", workspace: "/tmp/beta", status: .closed)
        let status = MenuBarStatus(sessions: [newer, closed, alpha, older], runtimes: [:])
        #expect(status.projects.map(\.name) == ["Alpha", "zeta"])
        #expect(status.projects.map(\.path) == ["/tmp/Alpha", "/Users/me/zeta"])
        #expect(status.projects.map { $0.sessions.map(\.sessionKey) } == [["alpha"], ["older", "newer"]])
        #expect(status.projects[1].sessions.map(\.title) == ["Fix the login bug", "New session"])
        #expect(status.projects[1].sessions.map(\.status) == [.idle, .needsAttention])
        #expect(status.runningAgents == 0 && status.waitingCount == 0)
    }

    /// No sessions: nothing runs, nothing waits, nothing is listed.
    @Test func nothingAtAll() {
        #expect(MenuBarStatus(sessions: [], runtimes: [:]) == MenuBarStatus(sessions: [manifestEntry("c", status: .closed)], runtimes: [:]))
        #expect(MenuBarStatus(sessions: [], runtimes: [:]).projects.isEmpty)
    }

    private func main(_ status: AgentStatus) -> AgentInfo {
        AgentInfo(id: "Main", kind: "main", status: status)
    }

    private func agent(_ id: String, _ status: AgentStatus, parent: String = "Main") -> AgentInfo {
        AgentInfo(id: id, kind: "task", parentId: parent, status: status)
    }
}
