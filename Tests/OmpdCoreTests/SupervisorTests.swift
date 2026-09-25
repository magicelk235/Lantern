import Darwin
import Foundation
import IDEProtocol
import Testing

@testable import OmpdCore

/// `SessionSupervisor` over the fake omp TUI on real session PTYs, with a scripted bridge.
@Suite(.timeLimit(.minutes(2)))
struct SupervisorTests {
    @Test func startRunsTheTUIOnASessionPTYWithTheLaunchSpecAndBridgeCredentials() async throws {
        let fixture = try await SupervisorFixture()
        try await fixture.supervisor.start(.fresh, cols: 100, rows: 30)
        let pty = try await fixture.pty()
        #expect(pty.sessionKey == fixture.key && pty.running && pty.cols == 100 && pty.rows == 30)
        let sessionDir = try await fixture.entry.launch.sessionDir ?? ""
        #expect(pty.command == [
            fixture.omp.executable, "--model", "anthropic/claude-haiku-4-5", "--approval-mode", "yolo", "--session-dir", sessionDir,
            "-e", "/fake/ide-bridge.ts", "--thinking", "off",
        ])
        try await fixture.waitForStatus(.idle)
        let environment = fixture.omp.environment(of: try #require(pty.pid))
        #expect(environment[BridgeCredentials.sessionKeyVariable] == fixture.key)
        #expect(environment[BridgeCredentials.tokenVariable] == String(repeating: "0", count: 64))
        #expect(environment[BridgeCredentials.daemonPIDVariable] == String(getpid()))
        #expect(environment["OMP_PROFILE"] == "work" && environment["TERM"] == "xterm-256color" && environment["COLORTERM"] == "truecolor")
        #expect(environment["FAKE_OMP_DIR"] != nil, "starts from the daemon environment")

        // The hello names the session file: into the manifest, and owned (by path) from now on.
        let entry = try await fixture.entry
        let pid = try #require(pty.pid)
        let file = try #require(fixture.omp.sessionFile(of: pid))
        #expect(entry.sessionFile == file && entry.sessionId == "fake-session" && entry.ptyId == pty.ptyId)
        #expect(fixture.locks.held == [file])
        await fixture.finish()
    }

    @Test func resumeTakesOwnershipBeforeSpawningAndRefusesAFileOwnedElsewhere() async throws {
        let spawnsAtAcquire = Box<[Int]>([])
        let omp = Box<FakeOmp?>(nil)
        let locks = FakeLocks { _ in spawnsAtAcquire.mutate { $0.append(omp.value?.lines("argv").count ?? -1) } }
        let fixture = try await SupervisorFixture(locks: locks) { $0.sessionFile = "/placeholder" }
        omp.mutate { $0 = fixture.omp }
        let file = fixture.temp.url.appending(path: "old.jsonl").path(percentEncoded: false)
        FileManager.default.createFile(atPath: file, contents: Data("{}\n".utf8))
        try await fixture.manifest.updateEntry(fixture.key) { $0.sessionFile = file }

        try await fixture.supervisor.start(.resume)
        try await fixture.waitForStatus(.idle)
        #expect(spawnsAtAcquire.value == [0])
        #expect(fixture.omp.lines("argv").last?.contains("--resume \(file)") == true)
        #expect(try await fixture.entry.sessionFile == file)
        await fixture.finish()

        let busy = try await SupervisorFixture { $0.sessionFile = file }
        busy.locks.holdElsewhere(file)
        await #expect(throws: DaemonError.self) { try await busy.supervisor.start(.resume) }
        #expect(try await busy.entry.status == .needsAttention)
        #expect(busy.omp.lines("argv").isEmpty)
        await busy.finish()
    }

    @Test func bridgeEventsDriveStatusTitleAndOwnership() async throws {
        let fixture = try await SupervisorFixture()
        try await fixture.supervisor.start(.fresh)
        try await fixture.waitForStatus(.idle)
        #expect(try await fixture.entry.lastActiveAt == nil)

        await fixture.bridge.push("activity", ["state": "busy"], to: fixture.key)
        try await fixture.waitForStatus(.busy)
        #expect(try await fixture.entry.lastActiveAt != nil)
        await fixture.bridge.push("title", ["title": "Fix the build"], to: fixture.key)
        try await eventually("title") { try await fixture.entry.title == "Fix the build" }
        await fixture.bridge.push("activity", ["state": "idle"], to: fixture.key)
        try await fixture.waitForStatus(.idle)

        // `/new` inside the TUI: the session lives in another (not yet written) file, and ownership follows it.
        let next = fixture.temp.url.appending(path: "next.jsonl").path(percentEncoded: false)
        await fixture.bridge.push(
            "session_switch", ["isMain": true, "reason": "new", "session": ["id": "next-id", "file": .string(next), "title": nil]],
            to: fixture.key)
        try await eventually("ownership follows the switch") { fixture.locks.held == [next] }
        let switched = try await fixture.entry
        #expect(switched.sessionFile == next && switched.sessionId == "next-id" && switched.title == nil)
        await fixture.finish()
    }

    @Test func quittingOmpInItsTUIClosesTheSessionAndKeepsItsScreen() async throws {
        let fixture = try await SupervisorFixture()
        try await fixture.supervisor.start(.fresh)
        try await fixture.waitForStatus(.idle)
        let pty = try await fixture.pty()
        try await fixture.type("exit")
        try await fixture.waitForStatus(.closed)
        let entry = try await fixture.entry
        #expect(!entry.closedByUser && entry.ptyId == pty.ptyId)
        #expect(await fixture.pool.info(pty.ptyId)?.running == false)
        #expect(fixture.locks.held.isEmpty)
        #expect(fixture.omp.lines("argv").count == 1, "not respawned")
        #expect(fixture.notices.value.map(\.level) == ["info"])
        await fixture.finish()
    }

    @Test func anUnexpectedExitResumesIntoANewPTYThatContinuesTheScreen() async throws {
        let fixture = try await SupervisorFixture()
        try await fixture.supervisor.start(.fresh)
        try await fixture.waitForStatus(.idle)
        let old = try await fixture.pty()
        try await fixture.type("before-crash")
        try await eventually("echo") { fixture.omp.lines("input").contains("before-crash") }
        fixture.published.mutate { $0 = [] }

        try await fixture.type("crash")
        let new = try await eventuallyValue("respawn") { () -> PTYID? in
            let entry = try await fixture.entry
            return entry.status == .idle && entry.ptyId != old.ptyId ? entry.ptyId : nil
        }
        #expect(fixture.omp.lines("argv").count == 2)
        let file = try #require(try await fixture.entry.sessionFile)
        #expect(fixture.omp.lines("argv").last?.contains("--resume \(file)") == true)
        #expect(await fixture.pool.info(old.ptyId) == nil)
        let screen = screenLines(try await fixture.pool.attach(new, subscriber: UUID()) { _ in })
        let divider = try #require(screen.firstIndex(of: "— terminal restarted —"))
        #expect(screen[..<divider].contains("echo:before-crash"))
        #expect(fixture.notices.value.map(\.level) == ["warning", "info"])
        #expect(fixture.notices.value.first?.message.contains("exit code 3") == true)

        // Clients never see the session point at a PTY that is not listed, nor lose the old one before the switch.
        let published = fixture.published.value
        let listed = try #require(published.firstIndex { if case .ptys(let ids) = $0 { ids.contains(new) } else { false } })
        let pointed = try #require(published.firstIndex { $0 == .sessions(ptyId: new, status: .resuming) })
        let dropped = try #require(published.firstIndex { if case .ptys(let ids) = $0 { !ids.contains(old.ptyId) } else { false } })
        #expect(published.prefix(listed).contains(.sessions(ptyId: old.ptyId, status: .interrupted)))
        #expect(listed < pointed && pointed < dropped)
        await fixture.finish()
    }

    @Test func aCrashLoopGivesUpAfterThreeRespawns() async throws {
        let fixture = try await SupervisorFixture()
        try await fixture.supervisor.start(.fresh)
        try await fixture.waitForStatus(.idle)
        FileManager.default.createFile(atPath: fixture.omp.file("crash-at-start").path(percentEncoded: false), contents: nil)
        try await fixture.type("crash")
        try await fixture.waitForStatus(.needsAttention)
        #expect(fixture.omp.lines("argv").count == 4, "the first run and three respawns")
        #expect(fixture.notices.value.last?.level == "error")
        #expect(fixture.notices.value.last?.message.contains("keeps exiting") == true)
        await fixture.finish()
    }

    @Test func closingTheSessionStopsOmpThroughTheBridge() async throws {
        let fixture = try await SupervisorFixture()
        try await fixture.supervisor.start(.fresh)
        try await fixture.waitForStatus(.idle)
        let pty = try await fixture.pty()
        let started = ContinuousClock.now
        await fixture.supervisor.stop(.user)
        #expect(ContinuousClock.now - started < .seconds(2))
        #expect(await fixture.bridge.calls == ["session.shutdown"])
        #expect(fixture.omp.lines("events") == ["graceful"])
        let entry = try await fixture.entry
        let file = try #require(entry.sessionFile)
        #expect(FakeOmp.sessionExits(file) == ["normal"])
        #expect(entry.status == .closed && entry.closedByUser && entry.ptyId == nil)
        #expect(await fixture.pool.info(pty.ptyId) == nil)
        #expect(fixture.locks.held.isEmpty)
        await fixture.finish()
    }

    @Test func withoutABridgeTheStopHangsUpTheTUI() async throws {
        let fixture = try await SupervisorFixture(bridgeConnects: false)
        try await fixture.supervisor.start(.fresh)
        try await fixture.waitForStatus(.idle)
        #expect(fixture.notices.value.first?.message.contains("did not connect") == true)
        let pid = try #require(try await fixture.pty().pid)
        let file = try await eventuallyValue("the TUI is up") { fixture.omp.sessionFile(of: pid) }
        await fixture.supervisor.stop(.user)
        #expect(await fixture.bridge.calls.isEmpty)
        #expect(fixture.omp.lines("events") == ["hup"])
        #expect(FakeOmp.sessionExits(file) == ["signal"])
        #expect(try await fixture.entry.status == .closed)
        await fixture.finish()
    }

    @Test func aTUIThatIgnoresHangupIsKilled() async throws {
        let fixture = try await SupervisorFixture(bridgeConnects: false, environment: ["FAKE_OMP_HUP": "ignore"])
        try await fixture.supervisor.start(.fresh)
        let pid = try #require(try await fixture.pty().pid)
        try await eventually("the TUI is up") { fixture.omp.sessionFile(of: pid) != nil }
        let started = ContinuousClock.now
        await fixture.supervisor.stop(.daemonShutdown)
        let elapsed = ContinuousClock.now - started
        #expect(elapsed >= .seconds(3) && elapsed < .seconds(8), "SIGHUP waits timings.stop, then SIGKILL")
        #expect(kill(pid, 0) != 0)
        #expect(fixture.notices.value.last?.message.contains("killing its process group") == true)
        #expect(try await fixture.entry.status != .closed, "a daemon shutdown leaves the session to be resumed")
        await fixture.finish()
    }

    @Test func aDaemonShutdownLeavesTheSessionResumable() async throws {
        let fixture = try await SupervisorFixture()
        try await fixture.supervisor.start(.fresh)
        try await fixture.waitForStatus(.idle)
        await fixture.supervisor.stop(.daemonShutdown)
        #expect(fixture.omp.lines("events") == ["graceful"])
        let entry = try await fixture.entry
        let file = try #require(entry.sessionFile)
        #expect(entry.status == .idle && !entry.closedByUser && FakeOmp.sessionExits(file) == ["normal"])
        await fixture.finish()
    }

    @Test(arguments: ["file", "missing file", "no file"])
    func restoreAfterADaemonRestart(_ case: String) async throws {
        let fixture = try await SupervisorFixture { entry in
            entry.status = .interrupted
            entry.sessionFile = `case` == "no file" ? nil : "/tmp/od-restore-\(UUID().uuidString).jsonl"
        }
        let file = try await fixture.entry.sessionFile
        if `case` == "file", let file { FileManager.default.createFile(atPath: file, contents: Data("{}\n".utf8)) }
        defer { if let file { try? FileManager.default.removeItem(atPath: file) } }
        await fixture.supervisor.restoreAfterDaemonStart()
        switch `case` {
        case "file":
            try await fixture.waitForStatus(.idle)
            #expect(fixture.omp.lines("argv").last?.contains("--resume \(file ?? "")") == true)
        case "missing file":
            try await fixture.waitForStatus(.idle)
            #expect(fixture.omp.lines("argv").last?.contains("--resume") == false, "started afresh")
            let pid = try #require(try await fixture.pty().pid)
            #expect(try await fixture.entry.sessionFile == fixture.omp.sessionFile(of: pid))
        default:
            #expect(try await fixture.entry.status == .needsAttention)
            #expect(fixture.omp.lines("argv").isEmpty)
        }
        await fixture.finish()
    }

    @Test func aClosedSessionReopensUnderItsKey() async throws {
        let fixture = try await SupervisorFixture()
        try await fixture.supervisor.start(.fresh)
        try await fixture.waitForStatus(.idle)
        await fixture.supervisor.stop(.user)
        try await fixture.supervisor.reopen(workspace: fixture.workspace, cols: 90, rows: 25)
        try await fixture.waitForStatus(.idle)
        let entry = try await fixture.entry
        #expect(!entry.closedByUser && entry.ptyId != nil)
        #expect(try await fixture.pty().cols == 90)
        let file = try #require(entry.sessionFile)
        #expect(fixture.omp.lines("argv").last?.contains("--resume \(file)") == true)
        await #expect(throws: DaemonError.self) { try await fixture.supervisor.reopen(workspace: fixture.workspace, cols: 90, rows: 25) }
        await fixture.finish()
    }

    @Test func aMissingWorkspaceNeedsAttention() async throws {
        let fixture = try await SupervisorFixture { $0.workspace = "/nonexistent/workspace" }
        await #expect(throws: DaemonError.self) { try await fixture.supervisor.start(.fresh) }
        #expect(try await fixture.entry.status == .needsAttention)
        #expect(fixture.notices.value.first?.message.contains("does not exist") == true)
        #expect(fixture.omp.lines("argv").isEmpty)
        await fixture.finish()
    }
}
