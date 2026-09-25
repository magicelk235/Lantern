import Foundation
import IDEProtocol
import IDETransport
import Testing

@testable import OmpdCore

/// While no omp IDE window (`ClientKind.app`) is connected, every session is paused, and a window connecting
/// resumes what ompd paused. The scripted bridge plays omp's pause gate; `cli` clients stand in for `ompd status`.
@Suite(.timeLimit(.minutes(2)))
struct DaemonPauseTests {
    @Test func theLastWindowClosingPausesEverySessionAfterTheGraceAndTheNextOneResumesThem() async throws {
        let fixture = try await DaemonFixture(pauseGrace: .milliseconds(1500))
        let window = try await fixture.client()
        let busy = try await fixture.createSession(window).sessionKey
        let idle = try await fixture.createSession(window).sessionKey
        try await window.waitForStatus(busy, .idle)
        try await window.waitForStatus(idle, .idle)
        await fixture.bridge.push("activity", ["state": "busy"], to: busy)
        try await window.waitForStatus(busy, .busy)
        let status = try await fixture.client(.cli)

        await window.close()
        try await Task.sleep(for: .milliseconds(700))
        #expect(await fixture.bridge.calls.isEmpty, "nothing is paused within the grace")
        try await status.waitForStatus(busy, .paused)
        try await status.waitForStatus(idle, .paused)
        #expect(await fixture.bridge.pausedBy(busy) == .daemon)
        #expect(await fixture.bridge.pausedBy(idle) == .daemon)
        #expect(status.pushes.contains { push in
            guard case .sessions(let list) = push else { return false }
            return list.sessions.count == 2 && list.sessions.allSatisfy { $0.status == .paused }
        })

        let reopened = try await fixture.client()
        // Each session comes back to what its main agent was doing underneath the pause.
        try await reopened.waitForStatus(busy, .busy)
        try await reopened.waitForStatus(idle, .idle)
        #expect(await fixture.bridge.calls.sorted() == ["session.pause", "session.pause", "session.resume", "session.resume"])
        #expect(await fixture.bridge.pausedBy(busy) == nil)
        #expect(await fixture.bridge.pausedBy(idle) == nil)
        await status.close()
        await reopened.close()
        await fixture.daemon.shutdown()
    }

    @Test func aWindowReconnectingWithinTheGracePausesNothing() async throws {
        let fixture = try await DaemonFixture(pauseGrace: .seconds(2))
        let window = try await fixture.client()
        let key = try await fixture.createSession(window).sessionKey
        try await window.waitForStatus(key, .idle)
        await window.close()
        try await Task.sleep(for: .milliseconds(300))
        let relaunched = try await fixture.client()
        try await Task.sleep(for: .seconds(3))
        #expect(await fixture.bridge.calls.isEmpty)
        #expect(try await relaunched.entry(key).status == .idle)
        await relaunched.close()
        await fixture.daemon.shutdown()
    }

    @Test func cliClientsNeitherKeepSessionsRunningNorResumeThem() async throws {
        let fixture = try await DaemonFixture(pauseGrace: .milliseconds(500))
        let window = try await fixture.client()
        let key = try await fixture.createSession(window).sessionKey
        try await window.waitForStatus(key, .idle)
        let watching = try await fixture.client(.cli)
        await window.close()
        try await watching.waitForStatus(key, .paused)

        let status = try await fixture.client(.cli)
        #expect(try await status.client.call(DaemonStatus.self, Empty()).sessions.map(\.status) == [.paused])
        try await Task.sleep(for: .milliseconds(500))
        #expect(await fixture.bridge.calls == ["session.pause"])
        #expect(await fixture.bridge.pausedBy(key) == .daemon)
        await status.close()
        await watching.close()
        await fixture.daemon.shutdown()
    }

    @Test func aPauseTheUserEngagedOutlastsWindowsComingAndGoing() async throws {
        let fixture = try await DaemonFixture(pauseGrace: .milliseconds(500))
        let window = try await fixture.client()
        let mine = try await fixture.createSession(window).sessionKey
        let other = try await fixture.createSession(window).sessionKey
        try await window.waitForStatus(mine, .idle)
        try await window.waitForStatus(other, .idle)
        await fixture.bridge.userPause(mine)
        try await window.waitForStatus(mine, .paused)

        let watching = try await fixture.client(.cli)
        await window.close()
        try await watching.waitForStatus(other, .paused)
        let reopened = try await fixture.client()
        try await reopened.waitForStatus(other, .idle)
        try await Task.sleep(for: .milliseconds(300))
        #expect(try await reopened.entry(mine).status == .paused)
        #expect(await fixture.bridge.pausedBy(mine) == .user)
        #expect(await fixture.bridge.sessionCalls.filter { $0.sessionKey == mine }.isEmpty, "ompd neither paused nor resumed it")

        // The user dismisses omp's pause screen.
        await fixture.bridge.userResume(mine)
        try await reopened.waitForStatus(mine, .idle)
        await watching.close()
        await reopened.close()
        await fixture.daemon.shutdown()
    }

    @Test func anOmpRespawnedWhileNoWindowIsConnectedIsPausedAfterItsHello() async throws {
        let fixture = try await DaemonFixture(pauseGrace: .milliseconds(500))
        let window = try await fixture.client()
        let entry = try await fixture.createSession(window)
        try await window.waitForStatus(entry.sessionKey, .idle)
        let watching = try await fixture.client(.cli)
        await window.close()
        try await watching.waitForStatus(entry.sessionKey, .paused)

        // omp crashes while no window is open: the respawned omp starts with its gate open and is paused at its hello.
        let crashed = try #require(entry.ptyId)
        _ = try await watching.client.call(PTYWrite.self, .init(ptyId: crashed, data: Data("crash\n".utf8)))
        try await eventually("respawned") { try await watching.entry(entry.sessionKey).ptyId != crashed }
        try await watching.waitForStatus(entry.sessionKey, .paused)
        #expect(await fixture.bridge.calls == ["session.pause", "session.pause"])
        #expect(await fixture.bridge.pausedBy(entry.sessionKey) == .daemon)

        let reopened = try await fixture.client()
        try await reopened.waitForStatus(entry.sessionKey, .idle)
        await watching.close()
        await reopened.close()
        await fixture.daemon.shutdown()
    }

    @Test func aDaemonStartedWithoutAWindowPausesTheSessionsItRestores() async throws {
        let fixture = try await DaemonFixture(pauseGrace: .milliseconds(500))
        let window = try await fixture.client()
        let key = try await fixture.createSession(window).sessionKey
        try await window.waitForStatus(key, .idle)
        await window.close()
        await fixture.daemon.shutdown()

        // As at login: ompd starts and resumes the session before any window opens.
        let restarted = try await fixture.restarted()
        await restarted.daemon.restore()
        let watching = try await restarted.client(.cli)
        try await watching.waitForStatus(key, .paused)
        #expect(await restarted.bridge.calls == ["session.pause"])

        let window2 = try await restarted.client()
        try await window2.waitForStatus(key, .idle)
        #expect(await restarted.bridge.calls == ["session.pause", "session.resume"])
        await watching.close()
        await window2.close()
        await restarted.daemon.shutdown()
    }

    @Test func anOmpThatCannotPauseIsReportedAndKeepsWorking() async throws {
        let fixture = try await DaemonFixture(pausable: false, pauseGrace: .milliseconds(300))
        let window = try await fixture.client()
        let key = try await fixture.createSession(window).sessionKey
        try await window.waitForStatus(key, .idle)
        try await eventually("the warning that it will not pause") {
            window.pushes.contains { push in
                guard case .notice(let notice) = push else { return false }
                return notice.sessionKey == key && notice.level == "warning" && notice.message.contains("cannot be paused")
            }
        }
        let watching = try await fixture.client(.cli)
        await window.close()
        try await Task.sleep(for: .seconds(1))
        #expect(try await watching.entry(key).status == .idle)
        #expect(await fixture.bridge.calls.isEmpty)
        await watching.close()
        await fixture.daemon.shutdown()
    }
}
