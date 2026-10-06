import Darwin
import Foundation
import IDEProtocol
import IDETransport
import Testing

@testable import OmpdCore

/// `Daemon` end to end through the real `IDEServer`/`IDEClient`, with the fake omp TUI behind it.
@Suite(.timeLimit(.minutes(2)))
struct DaemonTests {
    static let allMethods = [
        DaemonStatus.name, SessionCreate.name, SessionOpen.name, ListSessions.name, SessionClose.name, SessionForget.name,
        PTYOpen.name, PTYAttach.name, PTYDetach.name, PTYWrite.name, PTYResize.name, PTYClose.name, PTYList.name,
        PTYProcesses.name,
    ]

    @Test func routerServesEveryMethodAndSessionPTYsBehaveLikeTerminals() async throws {
        let fixture = try await DaemonFixture()
        let connected = try await fixture.client()
        let client = connected.client
        var served: Set<String> = []

        let status = try await client.call(DaemonStatus.self, Empty())
        served.insert(DaemonStatus.name)
        #expect(status.daemonVersion == ompdVersion && status.pid == getpid() && !status.readOnly && status.sessions.isEmpty)

        let entry = try await fixture.createSession(connected)
        served.insert(SessionCreate.name)
        let ptyId = try #require(entry.ptyId)
        #expect(entry.launch.ompPath == fixture.omp.executable && entry.launch.ompVersion == "18.3.1")
        #expect(entry.launch.extraArgs == ["--thinking", "off"] && entry.launch.sessionDir != nil)
        #expect(entry.workspace == (try Daemon.canonicalDirectory(fixture.workspace)))
        try await connected.waitForStatus(entry.sessionKey, .idle)
        #expect(try await client.call(ListSessions.self, Empty()).sessions.map(\.sessionKey) == [entry.sessionKey])
        served.insert(ListSessions.name)

        // The session's TUI is a PTY like any other, except that it closes with its session.
        try await eventually("the TUI's first paint") {
            screenLines(try await client.call(PTYAttach.self, .init(ptyId: ptyId))).contains { $0.hasPrefix("fake omp") }
        }
        served.insert(PTYAttach.name)
        _ = try await client.call(PTYWrite.self, .init(ptyId: ptyId, data: Data("hello\n".utf8)))
        served.insert(PTYWrite.name)
        try await eventually("typed input echoed live") { connected.output(ptyId).contains("echo:hello") }
        _ = try await client.call(PTYResize.self, .init(ptyId: ptyId, cols: 110, rows: 32))
        served.insert(PTYResize.name)
        let refused = await #expect(throws: DaemonError.self) { try await client.call(PTYClose.self, .init(ptyId: ptyId)) }
        served.insert(PTYClose.name)
        #expect(refused?.code == .badParams)

        // Adopt a session file omp wrote elsewhere; opening it twice is refused.
        let other = fixture.temp.url.appending(path: "other.jsonl").path(percentEncoded: false)
        FileManager.default.createFile(atPath: other, contents: Data())
        let opened = try await client.call(SessionOpen.self, .init(sessionFile: other, workspace: fixture.workspace, cols: 80, rows: 24))
        served.insert(SessionOpen.name)
        #expect(opened.sessionKey != entry.sessionKey && opened.ptyId != nil)
        #expect(fixture.omp.lines("argv").last?.contains("--resume \(Daemon.canonicalFile(other) ?? other)") == true)
        let busy = await #expect(throws: DaemonError.self) {
            try await client.call(SessionOpen.self, .init(sessionFile: other, workspace: fixture.workspace))
        }
        #expect(busy?.code == .sessionBusy)

        _ = try await client.call(SessionClose.self, .init(sessionKey: entry.sessionKey))
        served.insert(SessionClose.name)
        let closed = try await connected.entry(entry.sessionKey)
        #expect(closed.status == .closed && closed.closedByUser && closed.ptyId == nil)
        #expect(fixture.omp.lines("events") == ["graceful"])
        _ = try await client.call(SessionForget.self, .init(sessionKey: entry.sessionKey))
        served.insert(SessionForget.name)
        #expect(try await client.call(ListSessions.self, Empty()).sessions.map(\.sessionKey) == [opened.sessionKey])

        let pty = try await client.call(PTYOpen.self, .init(cwd: fixture.workspace, command: ["/bin/sh", "-c", "printf ready; exec cat"], cols: 80, rows: 24))
        served.insert(PTYOpen.name)
        #expect(pty.sessionKey == nil)
        _ = try await client.call(PTYAttach.self, .init(ptyId: pty.ptyId))
        _ = try await client.call(PTYWrite.self, .init(ptyId: pty.ptyId, data: Data("echoed\n".utf8)))
        try await eventually("live terminal output") { connected.output(pty.ptyId).contains("echoed") }
        let listed = try await client.call(PTYList.self, Empty()).ptys
        served.insert(PTYList.name)
        #expect(listed.map(\.ptyId) == [opened.ptyId, pty.ptyId] && listed.map(\.sessionKey) == [opened.sessionKey, nil])
        // `cat` is the PTY's own program: nothing else would end with it.
        #expect(try await client.call(PTYProcesses.self, .init(ptyId: pty.ptyId)).processes.isEmpty)
        served.insert(PTYProcesses.name)
        _ = try await client.call(PTYDetach.self, .init(ptyId: pty.ptyId))
        served.insert(PTYDetach.name)
        _ = try await client.call(PTYClose.self, .init(ptyId: pty.ptyId))
        #expect(try await client.call(PTYList.self, Empty()).ptys.map(\.ptyId) == [opened.ptyId])

        #expect(served == Set(Self.allMethods))
        await connected.close()
        await fixture.daemon.shutdown()
    }

    @Test func aRespawnListsTheNewPTYBeforeTheSessionPointsToIt() async throws {
        let fixture = try await DaemonFixture()
        let connected = try await fixture.client()
        let entry = try await fixture.createSession(connected)
        try await connected.waitForStatus(entry.sessionKey, .idle)
        let old = try #require(entry.ptyId)
        _ = try await connected.client.call(PTYWrite.self, .init(ptyId: old, data: Data("crash\n".utf8)))
        let new = try await eventuallyValue("respawned") { () -> PTYID? in
            let now = try await connected.entry(entry.sessionKey)
            return now.status == .idle && now.ptyId != old ? now.ptyId : nil
        }

        let pushes = connected.pushes
        let listed = try #require(pushes.firstIndex { if case .ptys(let list) = $0 { list.ptys.contains { $0.ptyId == new } } else { false } })
        let pointed = try #require(pushes.firstIndex {
            if case .sessions(let list) = $0 { list.sessions.contains { $0.sessionKey == entry.sessionKey && $0.ptyId == new } } else { false }
        })
        let dropped = try #require(pushes.indices.first { index in
            guard index > listed, case .ptys(let list) = pushes[index] else { return false }
            return !list.ptys.contains { $0.ptyId == old }
        })
        #expect(listed < pointed && pointed < dropped)
        #expect(pushes.contains { if case .notice(let n) = $0 { n.sessionKey == entry.sessionKey && n.level == "warning" } else { false } })
        await connected.close()
        await fixture.daemon.shutdown()
    }

    @Test func forgetDropsAStoppedSessionAndRefusesARunningOne() async throws {
        let fixture = try await DaemonFixture()
        let connected = try await fixture.client()
        let client = connected.client
        let running = try await fixture.createSession(connected)
        try await connected.waitForStatus(running.sessionKey, .idle)
        // A session ompd gave up on: it holds its file's ownership lock and keeps the PTY of its last screen.
        let gone = try await fixture.createSession(connected)
        try await connected.waitForStatus(gone.sessionKey, .idle)
        let file = try #require(try await connected.entry(gone.sessionKey).sessionFile)
        let crashAtStart = fixture.omp.file("crash-at-start").path(percentEncoded: false)
        FileManager.default.createFile(atPath: crashAtStart, contents: nil)
        _ = try await client.call(PTYWrite.self, .init(ptyId: try #require(gone.ptyId), data: Data("crash\n".utf8)))
        try await connected.waitForStatus(gone.sessionKey, .needsAttention)
        try FileManager.default.removeItem(atPath: crashAtStart)
        let lastScreen = try #require(try await connected.entry(gone.sessionKey).ptyId)
        #expect(fixture.locks.held.contains(file))

        let busy = await #expect(throws: DaemonError.self) { try await client.call(SessionForget.self, .init(sessionKey: running.sessionKey)) }
        #expect(busy?.code == .sessionBusy)
        let untouched = try await connected.entry(running.sessionKey)
        #expect(untouched.status == .idle && untouched.ptyId == running.ptyId)

        let before = connected.pushes.count
        _ = try await client.call(SessionForget.self, .init(sessionKey: gone.sessionKey))
        #expect(try await client.call(ListSessions.self, Empty()).sessions.map(\.sessionKey) == [running.sessionKey])
        #expect(try fixture.manifestOnDisk().sessions.map(\.sessionKey) == [running.sessionKey])
        try await eventually("a sessions push without the forgotten session") {
            connected.pushes[before...].contains {
                if case .sessions(let list) = $0 { list.sessions.map(\.sessionKey) == [running.sessionKey] } else { false }
            }
        }
        #expect(!fixture.locks.held.contains(file))
        #expect(try await client.call(PTYList.self, Empty()).ptys.map(\.ptyId) == [running.ptyId])
        #expect(FileManager.default.fileExists(atPath: file))
        let unknown = await #expect(throws: DaemonError.self) { try await client.call(SessionForget.self, .init(sessionKey: gone.sessionKey)) }
        #expect(unknown?.code == .noSuchSession)

        // Its file is nobody's now: opening it resumes it in a new session.
        let reopened = try await client.call(SessionOpen.self, .init(sessionFile: file, workspace: fixture.workspace))
        #expect(reopened.sessionKey != gone.sessionKey && reopened.ptyId != lastScreen)
        await connected.close()
        await fixture.daemon.shutdown()
    }

    @Test func aRestartClearsStalePTYsAndResumesTheSessionsThatWereOpen() async throws {
        let fixture = try await DaemonFixture()
        let connected = try await fixture.client()
        let kept = try await fixture.createSession(connected)
        let closed = try await fixture.createSession(connected)
        try await connected.waitForStatus(kept.sessionKey, .idle)
        try await connected.waitForStatus(closed.sessionKey, .idle)
        let keptFile = try #require(try await connected.entry(kept.sessionKey).sessionFile)
        _ = try await connected.client.call(PTYWrite.self, .init(ptyId: try #require(kept.ptyId), data: Data("before-restart\n".utf8)))
        try await eventually("typed") { fixture.omp.lines("input").contains("before-restart") }
        _ = try await connected.client.call(SessionClose.self, .init(sessionKey: closed.sessionKey))
        await connected.close()
        await fixture.daemon.shutdown()
        #expect(fixture.omp.lines("events") == ["graceful", "graceful"])
        #expect(FakeOmp.sessionExits(keptFile) == ["normal"])
        #expect(try fixture.manifestOnDisk().sessions.first { $0.sessionKey == kept.sessionKey }?.ptyId == kept.ptyId)

        let restarted = try await fixture.restarted()
        let again = try await restarted.client()
        // Nothing of the dead daemon's runtime survives: no PTY, no running omp.
        let stale = try #require(again.welcome.sessions.first { $0.sessionKey == kept.sessionKey })
        #expect(stale.ptyId == nil && stale.status == .interrupted)
        #expect(again.welcome.sessions.first { $0.sessionKey == closed.sessionKey }?.status == .closed)
        #expect(again.welcome.daemonStartedAt != connected.welcome.daemonStartedAt)

        await restarted.daemon.restore()
        try await again.waitForStatus(kept.sessionKey, .idle)
        let resumed = try await again.entry(kept.sessionKey)
        let resumedPTY = try #require(resumed.ptyId)
        #expect(resumedPTY != kept.ptyId)
        #expect(fixture.omp.lines("argv").count == 3, "two sessions, then one resume")
        #expect(fixture.omp.lines("argv").last?.contains("--resume \(keptFile)") == true)
        let screen = screenLines(try await again.client.call(PTYAttach.self, .init(ptyId: resumedPTY)))
        let divider = try #require(screen.firstIndex(of: "— terminal restarted —"))
        #expect(screen[..<divider].contains("echo:before-restart"))
        #expect(try await again.entry(closed.sessionKey).ptyId == nil)
        await again.close()
        await restarted.daemon.shutdown()
    }

    @Test func aManifestWriteFailureMakesTheDaemonReadOnly() async throws {
        let fixture = try await DaemonFixture()
        let connected = try await fixture.client()
        fixture.daemon.persistenceFailed(StorageError.system(operation: "write", path: "/sessions.json", code: ENOSPC))
        #expect(try await connected.client.call(DaemonStatus.self, Empty()).readOnly)
        try await eventually("read-only notice pushed to every client") {
            connected.pushes.contains {
                guard case .notice(let notice) = $0 else { return false }
                return notice.level == "error" && notice.sessionKey == nil && notice.message.contains("read-only")
            }
        }
        let refused = await #expect(throws: DaemonError.self) { try await fixture.createSession(connected) }
        #expect(refused?.code == .readOnly)
        // Terminals keep working.
        _ = try await connected.client.call(PTYOpen.self, .init(cwd: fixture.workspace, command: ["/bin/sh", "-c", "exec cat"], cols: 80, rows: 24))
        await connected.close()
        await fixture.daemon.shutdown()
    }

    @Test func wakeHealthChecksEverySessionThroughItsBridge() async throws {
        let fixture = try await DaemonFixture()
        let connected = try await fixture.client()
        let key = try await fixture.createSession(connected).sessionKey
        try await connected.waitForStatus(key, .idle)
        await fixture.daemon.didWake()
        #expect(await fixture.bridge.calls == ["session.info"])
        await connected.close()
        await fixture.daemon.shutdown()
    }

    @Test func badRequestsAreRefused() async throws {
        let fixture = try await DaemonFixture()
        let connected = try await fixture.client()
        let client = connected.client
        await #expect(throws: DaemonError.self) { try await client.call(SessionCreate.self, .init(workspace: "relative/path")) }
        await #expect(throws: DaemonError.self) { try await client.call(SessionCreate.self, .init(workspace: "/nonexistent/ws")) }
        await #expect(throws: DaemonError.self) { try await client.call(SessionOpen.self, .init(sessionFile: "/nonexistent.jsonl", workspace: fixture.workspace)) }
        await #expect(throws: DaemonError.self) { try await client.call(SessionClose.self, .init(sessionKey: "nope")) }
        await #expect(throws: DaemonError.self) { try await client.call(PTYAttach.self, .init(ptyId: "nope")) }
        #expect(try await client.call(ListSessions.self, Empty()).sessions.isEmpty)
        await connected.close()
        await fixture.daemon.shutdown()
    }
}
