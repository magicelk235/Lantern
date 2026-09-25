import Darwin
import Foundation
import IDEProtocol
import IDETransport
import Testing

@testable import OmpdCore

/// `Daemon` end to end through the real `IDEServer`/`IDEClient`, with the fake omp behind it.
@Suite struct DaemonTests {
    @Test func routerServesEveryDaemonMethod() async throws {
        let fixture = try await DaemonFixture()
        let connected = try await fixture.client()
        let client = connected.client
        var served: Set<String> = []

        let status = try await client.call(DaemonStatus.self, Empty())
        served.insert(DaemonStatus.name)
        #expect(status.daemonVersion == ompdVersion && status.pid == getpid() && !status.readOnly && status.sessions.isEmpty)

        let entry = try await fixture.createSession(connected)
        served.insert(SessionCreate.name)
        #expect(entry.status == .settled && entry.sessionFile == fixture.omp.sessionFile)
        #expect(entry.launch.ompPath == fixture.omp.executable && entry.launch.ompVersion == "18.3.1")
        #expect(entry.launch.extraArgs == ["--thinking", "off"] && entry.launch.sessionDir != nil)
        #expect(entry.workspace == (try Daemon.canonicalDirectory(fixture.workspace)))

        #expect(try await client.call(ListSessions.self, Empty()).sessions.map(\.sessionKey) == [entry.sessionKey])
        served.insert(ListSessions.name)

        let subscribed = try await client.call(Subscribe.self, .init(sessionKey: entry.sessionKey, since: 0))
        served.insert(Subscribe.name)
        #expect(subscribed.replayedThrough > 0)

        #expect(try await client.call(OmpCommand.self, .init(sessionKey: entry.sessionKey, command: ["type": "prompt", "message": "hi"])) == .null)
        served.insert(OmpCommand.name)
        try await connected.waitForEvent(entry.sessionKey, "session_settled") { $0.ompType == "session_settled" }

        let snapshot = try await client.call(SessionSnapshot.self, .init(sessionKey: entry.sessionKey))
        served.insert(SessionSnapshot.name)
        #expect(snapshot.state?["sessionId"] == "fake-session" && snapshot.entries?["leafId"] == "root")
        #expect(snapshot.lastSeq == connected.events(entry.sessionKey).last?.seq)

        await #expect(throws: DaemonError.self) {
            try await client.call(UIRespond.self, .init(sessionKey: entry.sessionKey, requestId: "none", response: ["confirmed": true]))
        }
        served.insert(UIRespond.name)

        _ = try await client.call(Unsubscribe.self, .init(sessionKey: entry.sessionKey))
        served.insert(Unsubscribe.name)

        // Adopt a session file omp wrote elsewhere.
        let other = fixture.temp.url.appending(path: "other.jsonl").path(percentEncoded: false)
        FileManager.default.createFile(atPath: other, contents: Data())
        let opened = try await client.call(SessionOpen.self, .init(sessionFile: other, workspace: fixture.workspace))
        served.insert(SessionOpen.name)
        #expect(opened.sessionKey != entry.sessionKey)
        #expect(fixture.omp.lines("argv").last?.hasSuffix("--resume \(Daemon.canonicalFile(other) ?? other) --thinking off") == true)
        await #expect(throws: DaemonError(.sessionBusy, "\(Daemon.canonicalFile(other) ?? other) is already open as session \(opened.sessionKey)")) {
            try await client.call(SessionOpen.self, .init(sessionFile: other, workspace: fixture.workspace))
        }

        _ = try await client.call(SessionClose.self, .init(sessionKey: entry.sessionKey))
        served.insert(SessionClose.name)
        let closed = try await client.call(ListSessions.self, Empty()).sessions.first { $0.sessionKey == entry.sessionKey }
        #expect(closed?.status == .closed && closed?.closedByUser == true)

        let pty = try await client.call(PTYOpen.self, .init(cwd: fixture.workspace, command: ["/bin/sh", "-c", "printf ready; exec cat"], cols: 80, rows: 24))
        served.insert(PTYOpen.name)
        try await eventually("pty output") {
            String(decoding: try await client.call(PTYAttach.self, .init(ptyId: pty.ptyId)).screen, as: UTF8.self).contains("ready")
        }
        served.insert(PTYAttach.name)
        _ = try await client.call(PTYWrite.self, .init(ptyId: pty.ptyId, data: Data("echoed\n".utf8)))
        served.insert(PTYWrite.name)
        try await eventually("live pty output pushed") {
            let output = connected.pushes.compactMap { if case .ptyOutput(let o) = $0, o.ptyId == pty.ptyId { o.data } else { nil } }
            return String(decoding: output.joined(), as: UTF8.self).contains("echoed")
        }
        _ = try await client.call(PTYResize.self, .init(ptyId: pty.ptyId, cols: 100, rows: 30))
        served.insert(PTYResize.name)
        let listed = try await client.call(PTYList.self, Empty()).ptys
        served.insert(PTYList.name)
        #expect(listed.map(\.ptyId) == [pty.ptyId] && listed.first?.cols == 100 && listed.first?.rows == 30)
        _ = try await client.call(PTYDetach.self, .init(ptyId: pty.ptyId))
        served.insert(PTYDetach.name)
        _ = try await client.call(PTYClose.self, .init(ptyId: pty.ptyId))
        served.insert(PTYClose.name)
        #expect(try await client.call(PTYList.self, Empty()).ptys.isEmpty)
        await #expect(throws: DaemonError.self) { try await client.call(PTYWrite.self, .init(ptyId: pty.ptyId, data: Data())) }

        #expect(served == Set(Self.allMethods))
        await connected.close()
        await fixture.daemon.shutdown()
    }

    static let allMethods = [
        DaemonStatus.name, SessionCreate.name, SessionOpen.name, ListSessions.name, SessionClose.name, Subscribe.name,
        Unsubscribe.name, SessionSnapshot.name, OmpCommand.name, UIRespond.name, PTYOpen.name, PTYAttach.name,
        PTYDetach.name, PTYWrite.name, PTYResize.name, PTYClose.name, PTYList.name,
    ]

    @Test func replayThenLiveIsContiguousAndIdenticalForEverySubscriber() async throws {
        let fixture = try await DaemonFixture()
        let a = try await fixture.client()
        let key = try await fixture.createSession(a).sessionKey
        _ = try await a.client.call(Subscribe.self, .init(sessionKey: key, since: 0))
        func prompt(_ n: Int) async throws {
            _ = try await a.client.call(OmpCommand.self, .init(sessionKey: key, command: ["type": "prompt", "message": .string("p\(n)")]))
        }
        try await prompt(1)
        try await prompt(2)
        try await a.waitForEvent(key, "two settles") { _ in a.events(key).filter { $0.ompType == "session_settled" }.count == 2 }

        // B joins mid-stream from an older seq while prompts keep running, drops, and resumes from its last seq.
        let b = try await fixture.client()
        let since: Seq = 3
        let first = try await b.client.call(Subscribe.self, .init(sessionKey: key, since: since))
        #expect(first.replayedThrough >= since)
        try await prompt(3)
        try await b.waitForSeq(key, first.replayedThrough + 1)
        let bSeenBeforeDrop = b.events(key)
        await b.close()
        try await prompt(4)
        let b2 = try await fixture.client()
        let resumeFrom = try #require(bSeenBeforeDrop.last?.seq)
        _ = try await b2.client.call(Subscribe.self, .init(sessionKey: key, since: resumeFrom))
        try await prompt(5)

        let lastSeq = try await eventuallyValue("journal settled 5 times") { () -> Seq? in
            let settles = a.events(key).filter { $0.ompType == "session_settled" }
            return settles.count == 5 ? a.events(key).last?.seq : nil
        }
        try await b2.waitForSeq(key, lastSeq)

        let aRecords = a.events(key)
        #expect(aRecords.map(\.seq) == Array(1...lastSeq))
        let bRecords = bSeenBeforeDrop + b2.events(key)
        #expect(bRecords.map(\.seq) == Array((since + 1)...lastSeq))
        #expect(try recordBytes(bRecords) == recordBytes(Array(aRecords.drop { $0.seq <= since })))
        await a.close()
        await b2.close()
        await fixture.daemon.shutdown()
    }

    @Test func unknownSinceGetsAResyncThenLiveEvents() async throws {
        let fixture = try await DaemonFixture()
        let connected = try await fixture.client()
        let key = try await fixture.createSession(connected).sessionKey
        let status = try await connected.client.call(ListSessions.self, Empty())
        let lastSeq = try #require(status.sessions.first?.lastSeq)
        let result = try await connected.client.call(Subscribe.self, .init(sessionKey: key, since: lastSeq + 100))
        #expect(result.replayedThrough == lastSeq)
        try await eventually("resync push") {
            connected.pushes.contains { if case .resync(let r) = $0 { r == Resync(sessionKey: key, lastSeq: lastSeq) } else { false } }
        }
        _ = try await connected.client.call(OmpCommand.self, .init(sessionKey: key, command: ["type": "prompt", "message": "x"]))
        try await connected.waitForEvent(key, "live settle") { $0.ompType == "session_settled" }
        let seqs = connected.events(key).map(\.seq)
        #expect(seqs.first == lastSeq + 1 && seqs == Array((lastSeq + 1)...(lastSeq + Seq(seqs.count))))
        await #expect(throws: DaemonError.self) { try await connected.client.call(Subscribe.self, .init(sessionKey: "nope", since: 0)) }
        await connected.close()
        await fixture.daemon.shutdown()
    }

    @Test func manifestChangesAreBroadcast() async throws {
        let fixture = try await DaemonFixture()
        let watcher = try await fixture.client()
        let creator = try await fixture.client()
        let entry = try await fixture.createSession(creator)
        try await eventually("sessions push with the settled session") {
            watcher.pushes.contains {
                if case .sessions(let list) = $0 { list.sessions.contains { $0.sessionKey == entry.sessionKey && $0.status == .settled } } else { false }
            }
        }
        await watcher.close()
        await creator.close()
        await fixture.daemon.shutdown()
    }

    @Test func manifestPersistsAndOpenSessionsResumeAfterARestart() async throws {
        let fixture = try await DaemonFixture()
        let connected = try await fixture.client()
        let kept = try await fixture.createSession(connected)
        _ = try await connected.client.call(OmpCommand.self, .init(sessionKey: kept.sessionKey, command: ["type": "prompt", "message": "hi"]))
        _ = try await connected.client.call(Subscribe.self, .init(sessionKey: kept.sessionKey, since: 0))
        try await connected.waitForEvent(kept.sessionKey, "settled") { $0.ompType == "session_settled" }
        await connected.close()

        await fixture.daemon.shutdown()
        #expect(fixture.omp.lines("events") == ["eof"])
        let onDisk = try fixture.manifestOnDisk()
        let persisted = try #require(onDisk.sessions.first { $0.sessionKey == kept.sessionKey })
        #expect(persisted.sessionFile == fixture.omp.sessionFile && !persisted.closedByUser)
        #expect(persisted.lastSettledAt != nil && persisted.lastSeq > 0)

        let restarted = try await fixture.restarted()
        await restarted.daemon.restore()
        #expect(fixture.omp.lines("argv").count == 2)
        #expect(fixture.omp.lines("argv").last?.hasSuffix("--resume \(fixture.omp.sessionFile) --thinking off") == true)
        let again = try await restarted.client()
        #expect(again.welcome.sessions.first { $0.sessionKey == kept.sessionKey }?.status == .settled)
        #expect(again.welcome.daemonStartedAt != connected.welcome.daemonStartedAt)
        _ = try await again.client.call(Subscribe.self, .init(sessionKey: kept.sessionKey, since: persisted.lastSeq))
        try await again.waitForEvent(kept.sessionKey, "resumed spawn") {
            if case .spawned(_, _, true)? = $0.daemonEvent { true } else { false }
        }
        let resumed = again.events(kept.sessionKey)
        #expect(resumed.first?.seq == persisted.lastSeq + 1)
        #expect(resumed.contains { $0.daemonEvent == .statusChanged(.resuming) })
        #expect(resumed.contains { if case .notice("info", let message)? = $0.daemonEvent { message.contains("resuming") } else { false } })
        // The pre-restart journal holds omp's graceful exit (stdin EOF => session_exit kind normal).
        let history = try await again.client.call(SessionSnapshot.self, .init(sessionKey: kept.sessionKey))
        #expect(history.state?["sessionFile"] == .string(fixture.omp.sessionFile))
        await again.close()
        await restarted.daemon.shutdown()
    }

    @Test func shutdownJournalsTheGracefulExitAndClosedSessionsStayClosed() async throws {
        let fixture = try await DaemonFixture()
        let connected = try await fixture.client()
        let open = try await fixture.createSession(connected)
        let closed = try await fixture.createSession(connected)
        _ = try await connected.client.call(OmpCommand.self, .init(sessionKey: open.sessionKey, command: ["type": "prompt", "message": "hi"]))
        _ = try await connected.client.call(SessionClose.self, .init(sessionKey: closed.sessionKey))
        await connected.close()
        await fixture.daemon.shutdown()

        let restarted = try await fixture.restarted()
        await restarted.daemon.restore()
        let again = try await restarted.client()
        _ = try await again.client.call(Subscribe.self, .init(sessionKey: open.sessionKey, since: 0))
        try await again.waitForEvent(open.sessionKey, "exit before the restart") {
            $0.daemonEvent == .exited(code: 0, signal: nil, sessionExitKind: "normal")
        }
        let sessions = try await again.client.call(ListSessions.self, Empty()).sessions
        #expect(sessions.first { $0.sessionKey == closed.sessionKey }?.status == .closed)
        #expect(sessions.first { $0.sessionKey == open.sessionKey }?.status == .settled)
        // Three spawns: two sessions before the restart, one resume after it.
        #expect(fixture.omp.lines("argv").count == 3)
        await again.close()
        await restarted.daemon.shutdown()
    }

    @Test func pendingDialogIsAnsweredThroughTheRouter() async throws {
        let fixture = try await DaemonFixture()
        try fixture.omp.script("prompt", [
            #"{"type":"extension_ui_request","id":"dlg-1","method":"select","title":"Allow tool: bash","options":["Approve","Deny"]}"#,
        ])
        try fixture.omp.script("answered", [
            #"{"type":"prompt_result","id":"__PROMPT__","agentInvoked":true,"status":"completed","sessionSettled":true}"#,
            #"{"type":"session_settled"}"#,
        ])
        let connected = try await fixture.client()
        let key = try await fixture.createSession(connected).sessionKey
        _ = try await connected.client.call(Subscribe.self, .init(sessionKey: key, since: 0))
        _ = try await connected.client.call(OmpCommand.self, .init(sessionKey: key, command: ["type": "prompt", "message": "run it"]))
        try await eventually("pending in the manifest") {
            try await connected.client.call(ListSessions.self, Empty()).sessions.first?.pending.uiRequests.first?.frameId == "dlg-1"
        }
        _ = try await connected.client.call(UIRespond.self, .init(sessionKey: key, requestId: "dlg-1", response: ["value": "Approve"]))
        try await connected.waitForEvent(key, "answered") { $0.daemonEvent == .uiAnswered(requestId: "dlg-1") }
        try await connected.waitForEvent(key, "settled") { $0.ompType == "session_settled" }
        #expect(fixture.omp.received.contains { $0 == ["type": "extension_ui_response", "id": "dlg-1", "value": "Approve"] })
        #expect(try await connected.client.call(ListSessions.self, Empty()).sessions.first?.pending == PendingRequests())
        await connected.close()
        await fixture.daemon.shutdown()
    }

    @Test func journalFailureMakesTheDaemonReadOnly() async throws {
        let fixture = try await DaemonFixture()
        let connected = try await fixture.client()
        let client = connected.client
        let key = try await fixture.createSession(connected).sessionKey
        fixture.daemon.journalFailed(key, StorageError.system(operation: "write", path: "/journal", code: ENOSPC))

        #expect(try await client.call(DaemonStatus.self, Empty()).readOnly)
        try await eventually("read-only notice pushed to every client") {
            connected.pushes.contains {
                guard case .event(let record) = $0, record.seq == 0, case .notice("error", let message)? = record.daemonEvent else { return false }
                return record.sessionKey == key && message.contains("read-only")
            }
        }
        let refusedPrompt = await #expect(throws: DaemonError.self) {
            try await client.call(OmpCommand.self, .init(sessionKey: key, command: ["type": "prompt", "message": "x"]))
        }
        #expect(refusedPrompt?.code == .readOnly)
        let refusedCreate = await #expect(throws: DaemonError.self) { try await fixture.createSession(connected) }
        #expect(refusedCreate?.code == .readOnly)
        // Reads and control still work: omp keeps being drained and answering.
        #expect(try await client.call(OmpCommand.self, .init(sessionKey: key, command: ["type": "get_state"]))["sessionId"] == "fake-session")
        #expect(!fixture.omp.received.contains { $0["type"] == "prompt" })
        await connected.close()
        await fixture.daemon.shutdown()
    }

    @Test func sleepPersistsTheManifestAndWakeHealthChecksEverySession() async throws {
        let fixture = try await DaemonFixture()
        let connected = try await fixture.client()
        let key = try await fixture.createSession(connected).sessionKey
        _ = try await connected.client.call(Subscribe.self, .init(sessionKey: key, since: 0))
        _ = try await connected.client.call(OmpCommand.self, .init(sessionKey: key, command: ["type": "prompt", "message": "hi"]))
        try await connected.waitForEvent(key, "settled") { $0.ompType == "session_settled" }

        await fixture.daemon.prepareForSleep()
        let lastSeq = try #require(connected.events(key).last?.seq)
        #expect(try fixture.manifestOnDisk().sessions.first { $0.sessionKey == key }?.lastSeq == lastSeq)

        await fixture.daemon.didWake()
        try await connected.waitForEvent(key, "health check notice") {
            guard case .notice("info", let message)? = $0.daemonEvent else { return false }
            return message.hasPrefix("Wake health check: omp answered get_state") && message.contains("settled: yes")
        }
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
        await #expect(throws: DaemonError.self) { try await client.call(OmpCommand.self, .init(sessionKey: "nope", command: ["type": "get_state"])) }
        #expect(try await client.call(ListSessions.self, Empty()).sessions.isEmpty)
        await connected.close()
        await fixture.daemon.shutdown()
    }
}

/// Polls until `value` returns non-nil.
func eventuallyValue<T: Sendable>(_ what: String, timeout: Duration = .seconds(10), _ value: @Sendable () async throws -> T?) async throws -> T {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if let found = try await value() { return found }
        try await Task.sleep(for: .milliseconds(20))
    }
    throw Timeout(what: what)
}
