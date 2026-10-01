import Darwin
import Foundation
import IDEProtocol
import Testing

@testable import OmpdCore

/// The in-place upgrade: handover file, descriptors kept across the exec, PTYs and sessions taken over by the
/// next image, bridges redialing, and the graceful fallback's decision.
@Suite(.timeLimit(.minutes(2)))
struct UpgradeTests {
    @Test func handoverFileRoundTripsAndIsRemovedOnceTaken() throws {
        let temp = try ShortTempDir()
        let url = temp.url.appending(path: "handover.json")
        let info = PTYInfo(ptyId: "p1", cwd: "/tmp", command: ["/bin/sh"], cols: 80, rows: 24, pid: 4242, running: true, sessionKey: "s1")
        var handover = DaemonHandover(
            startedAt: Date(timeIntervalSince1970: 1_790_000_000), pauseDemand: true,
            ptys: PTYPoolHandover(
                ptys: [PTYHandover(info: info, persistedEnv: ["A": "1"], sequence: 7, masterFD: 9, screen: Data("screen".utf8),
                                   scrollbackEraseHeld: [0x1B, 0x5B], pendingInput: Data("ls\n".utf8))],
                closing: [77], sessionScreens: ["s2": "p0"]),
            sessions: [SupervisorHandover(
                sessionKey: "s1",
                omp: RunningOmp(pid: 4242, ptyId: "p1", adopted: false, spawnedAt: Date(timeIntervalSince1970: 1_790_000_100),
                                activity: .busy, pausedBy: .user, bridge: true),
                lock: LockHandover(descriptor: 11, sessionFile: "/tmp/s1.jsonl"))],
            bridge: BridgeHandover(
                sessions: [.init(sessionKey: "s1", token: String(repeating: "a", count: 64), pid: 4242, terminal: nil)],
                terminals: ["t1": String(repeating: "b", count: 64)]))
        handover.instanceLock = 5
        try handover.write(to: url)
        var mode = stat()
        #expect(stat(url.path(percentEncoded: false), &mode) == 0 && mode.st_mode & 0o777 == 0o600)

        let taken = try DaemonHandover.take(from: url)
        #expect(!FileManager.default.fileExists(atPath: url.path(percentEncoded: false)), "it carries the bridges' tokens")
        #expect(taken.descriptors == [5, 9, 11])
        #expect(taken.startedAt == handover.startedAt && taken.pauseDemand)
        #expect(taken.ptys.ptys.first?.info == info && taken.ptys.ptys.first?.scrollbackEraseHeld == [0x1B, 0x5B])
        #expect(taken.ptys.ptys.first?.pendingInput == Data("ls\n".utf8) && taken.ptys.closing == [77])
        let omp = try #require(taken.sessions.first?.omp)
        #expect(omp.activity == .busy && omp.pausedBy == .user && omp.bridge)
        #expect(taken.bridge.terminals["t1"] == String(repeating: "b", count: 64))

        try Data(#"{"format":99}"#.utf8).write(to: url)
        #expect(throws: (any Error).self) { try DaemonHandover.take(from: url) }
    }

    @Test func handedOverDescriptorsLoseCloseOnExecAndGetItBack() throws {
        var pair: [Int32] = [-1, -1]
        #expect(pipe(&pair) == 0)
        defer { for fd in pair { close(fd) } }
        for fd in pair { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        try ProcessImage.inherit(pair)
        #expect(pair.allSatisfy { fcntl($0, F_GETFD) & FD_CLOEXEC == 0 })
        ProcessImage.closeOnExec(pair)
        #expect(pair.allSatisfy { fcntl($0, F_GETFD) & FD_CLOEXEC != 0 })

        // A descriptor that is not open fails the whole handover, and the ones already cleared are set again.
        #expect(throws: HandoverError.self) { try ProcessImage.inherit([pair[0], 987_654]) }
        #expect(fcntl(pair[0], F_GETFD) & FD_CLOEXEC != 0)
    }

    /// A shell loop keeps printing across the handover: the second pool reads on from where the first stopped, on the
    /// same master and child, and still reaps the child.
    @Test func ptysAreTakenOverWithTheirScreenAndChild() async throws {
        let temp = try ShortTempDir()
        let old = PTYPool(snapshotDirectory: temp.url.appending(path: "pty"), snapshotInterval: .seconds(3600))
        let script = "i=0; while :; do echo tick-$i; i=$((i+1)); sleep 0.1; done"
        let info = try await old.open(PTYOpen.Params(cwd: temp.path, command: ["/bin/sh", "-c", script], cols: 80, rows: 24))
        try await eventually("ticks") { screenLines(try await old.attach(info.ptyId, subscriber: UUID()) { _ in }).contains("tick-3") }
        let frozen = await old.freezeForHandover()
        let handed = try #require(frozen.ptys.first)
        let master = try #require(handed.masterFD)
        // The old pool keeps its descriptor (released at the end of the test); the new one gets its own, as after an exec.
        var copy = frozen
        copy.ptys[0].masterFD = dup(master)

        let new = PTYPool(snapshotDirectory: temp.url.appending(path: "pty"), snapshotInterval: .seconds(3600))
        let exit = Box<PTYExit?>(nil)
        await new.adopt(copy, onExit: [info.ptyId: { ended in exit.mutate { if $0 == nil { $0 = ended } } }])
        #expect(await new.info(info.ptyId)?.pid == info.pid)
        let before = screenLines(try await new.attach(info.ptyId, subscriber: UUID()) { _ in })
        #expect(before.contains("tick-3"), "the screen comes along")
        try await eventually("ticks after the handover") {
            screenLines(try await new.attach(info.ptyId, subscriber: UUID()) { _ in }).contains("tick-\(before.count + 10)")
        }
        try await new.signal(info.ptyId, SIGKILL)
        try await eventually("the exit, reaped by the new pool") { exit.value == PTYExit(code: nil, signal: SIGKILL) }
        try? await new.shutdown()
        await old.thaw()
        try? await old.shutdown()
    }

    @Test func aSessionIsTakenOverAndFollowsItsBridgeRedial() async throws {
        let fixture = try await SupervisorFixture(bridgeCapabilities: ["bridge.redial": true])
        try await fixture.supervisor.start(.fresh)
        try await fixture.waitForStatus(.idle)
        let pty = try await fixture.pty()
        #expect(await fixture.supervisor.handoverBlocker() == nil)

        // The bridge server hung up (a handover): the supervisor handles what came before, then waits for the redial.
        await fixture.bridge.dropConnection(fixture.key)
        let state = try await fixture.supervisor.handoverState(timeout: .seconds(5))
        let omp = try #require(state.omp)
        #expect(omp.pid == pty.pid && omp.ptyId == pty.ptyId && omp.bridge && !omp.adopted)
        #expect(state.lock?.sessionFile == fixture.locks.held.first.map(OwnershipLock.canonicalPath))

        // The next image: a supervisor of the same entry takes it over and gets the omp's exit from the pool.
        let next = SessionSupervisor(entry: try await fixture.entry, context: fixture.context)
        let onExit = await next.takeOver(state)
        #expect(onExit != nil)
        let hello = try await fixture.bridge.waitForHello(fixture.key, timeout: .seconds(5))
        await fixture.bridge.redial(fixture.key, hello: hello)
        await fixture.bridge.push("activity", ["state": "busy"], to: fixture.key)
        try await fixture.waitForStatus(.busy)
        #expect(fixture.omp.lines("argv").count == 1, "omp was not restarted")
        await next.stop(.daemonShutdown)
        await fixture.finish()
    }

    @Test func bridgeServerAcceptsTheSameOmpAgainAfterItsConnectionEnded() async throws {
        try await withBridgeServer { server in
            let credentials = await server.expect(sessionKey: "s1")
            await server.setExpectedPID(getpid(), for: "s1")
            let first = try FakeBridge(socketPath: server.socketPath)
            #expect(try await first.handshake(credentials)?["t"] == "welcome")
            // ompd stops writing; the bridge reads the end of its input and hangs up, as the real one does.
            async let quiet = server.quiesce(timeout: .seconds(5))
            #expect(try await first.next() == nil)
            first.close()
            #expect(await quiet, "the bridge hung up after ompd stopped writing")

            try await server.resumeListening()
            let waiting = Task { try await server.waitForRedial("s1") }
            let redial = try FakeBridge(socketPath: server.socketPath)
            #expect(try await redial.handshake(credentials)?["t"] == "welcome", "same token, same pid")
            #expect(try await waiting.value.pid == getpid())
            try redial.send(["t": "evt", "seq": 9, "ts": 0, "agentId": "Main", "kind": "activity", "data": ["state": "idle"]])
            redial.close()
            #expect(try await bridgeCollect(server.events("s1")).map { $0["kind"] } == ["activity"])

            // The credentials move to the next image, whose server takes the redial.
            let state = await server.handoverState()
            #expect(state.sessions.map(\.sessionKey) == ["s1"] && state.sessions.first?.pid == getpid())
        }
    }

    @Test func fallbackRestartsAtOnceOnlyWhenSettled() {
        let blocked = "the installed ompd cannot take over"
        #expect(UpgradePlan.decide(.auto, handoverBlocker: nil, installedStarts: true, unsettled: ["busy"]) == .handOver)
        #expect(UpgradePlan.decide(.auto, handoverBlocker: blocked, installedStarts: true, unsettled: []) == .restartNow)
        #expect(UpgradePlan.decide(.auto, handoverBlocker: blocked, installedStarts: true, unsettled: ["s1"]) == .wait)
        #expect(UpgradePlan.decide(.auto, handoverBlocker: blocked, installedStarts: false, unsettled: []) == .wait)
        #expect(UpgradePlan.decide(.whenSettled, handoverBlocker: blocked, installedStarts: true, unsettled: ["s1"]) == .restartWhenSettled)
        #expect(UpgradePlan.decide(.whenSettled, handoverBlocker: blocked, installedStarts: true, unsettled: []) == .restartNow)
        #expect(UpgradePlan.decide(.now, handoverBlocker: blocked, installedStarts: true, unsettled: ["s1"]) == .restartNow)
        #expect(SessionStatus.paused.isSettled && SessionStatus.idle.isSettled && !SessionStatus.busy.isSettled)
    }
}
