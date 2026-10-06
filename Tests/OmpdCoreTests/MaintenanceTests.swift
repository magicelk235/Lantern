import Darwin
import Foundation
import IDEProtocol
import Testing

@testable import OmpdCore

// Hardening: restart onto the omp installed now, free-space warnings, `omp gc`, and
// what of `$APP_SUPPORT/pty/` nothing refers to.

/// An omp at a fixed path whose version an upgrade changes: `--version` prints `version` (ompd runs it without the
/// session's environment); anything else is the fake omp TUI (`$FAKE_OMP_DIR/omp`), exec'd so its pid stays the one the
/// bridge expects.
private struct InstalledOmp {
    let path: String
    let versionFile: URL

    init(in temp: ShortTempDir, name: String = "omp-installed", version: String) throws {
        versionFile = temp.url.appending(path: "\(name).version")
        path = temp.url.appending(path: name).path(percentEncoded: false)
        try install(version)
        let script = """
            #!/bin/sh
            if [ "$1" = "--version" ]; then cat '\(versionFile.path(percentEncoded: false))'; exit 0; fi
            exec "$FAKE_OMP_DIR/omp" "$@"
            """
        try script.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    }

    /// What an upgrade leaves at `path`.
    func install(_ version: String) throws {
        try "omp/\(version)\n".write(to: versionFile, atomically: true, encoding: .utf8)
    }
}

private let recoveryCapabilities: [String: Bool] = ["session.prompt": true, "agent.message": true, "entry.append": true]

/// An in-flight turn in omp's JSONL: a prompt, a reply that called `bash`, the call started and never finished.
private func appendTurnInFlight(to file: String, command: String) throws {
    let stamp = Date().formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    let lines = [
        #"{"type":"message","id":"u1","timestamp":"\#(stamp)","message":{"role":"user","content":[{"type":"text","text":"go"}]}}"#,
        #"{"type":"message","id":"a1","timestamp":"\#(stamp)","message":{"role":"assistant","stopReason":"toolUse","content":[{"type":"toolCall","id":"t1","name":"bash","arguments":{"command":"\#(command)"}}]}}"#,
        #"{"type":"custom","customType":"tool_execution_start","timestamp":"\#(stamp)","data":{"toolCallId":"t1","toolName":"bash","args":{"command":"\#(command)"}}}"#,
    ]
    let handle = try #require(FileHandle(forWritingAtPath: file))
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8))
}

@Suite(.timeLimit(.minutes(1)))
struct SessionRestartTests {
    @Test func aRestartIsRefusedWhileTheAgentWorksUnlessForced() async throws {
        let temp = try ShortTempDir()
        let omp = try InstalledOmp(in: temp, version: "18.4.4")
        let fixture = try await SupervisorFixture { $0.launch.ompPath = omp.path }
        await #expect(throws: DaemonError.self) { try await fixture.supervisor.restart(force: false) }

        try await fixture.supervisor.start(.fresh)
        try await fixture.waitForStatus(.idle)
        await fixture.bridge.push("activity", ["state": "busy"], to: fixture.key)
        try await fixture.waitForStatus(.busy)
        do {
            try await fixture.supervisor.restart(force: false)
            Issue.record("restarted a busy session")
        } catch let error as DaemonError {
            #expect(error.code == .sessionBusy)
        }
        #expect(await !fixture.bridge.calls.contains("session.shutdown"))
        #expect(fixture.omp.lines("argv").count == 1)

        try await fixture.supervisor.restart(force: true)
        #expect(fixture.omp.lines("argv").count == 2)
        try await fixture.waitForStatus(.idle)
        await fixture.finish()
    }

    @Test func aRestartResumesTheConversationOnTheOmpInstalledNow() async throws {
        let temp = try ShortTempDir()
        let omp = try InstalledOmp(in: temp, version: "18.4.4")
        let fixture = try await SupervisorFixture { $0.launch.ompPath = omp.path }
        try await fixture.supervisor.start(.fresh)
        try await fixture.waitForStatus(.idle)
        let before = try await fixture.entry
        #expect(before.launch.ompVersion == "18.4.4" && before.ompUpgrade == nil)
        let file = try #require(before.sessionFile)
        let old = try await fixture.pty()
        try await fixture.type("before-restart")
        try await eventually("echo") { fixture.omp.lines("input").contains("before-restart") }

        try omp.install("18.4.8")
        try await fixture.supervisor.restart(force: false)
        try await fixture.waitForStatus(.idle)
        let after = try await fixture.entry
        #expect(after.launch.ompVersion == "18.4.8" && after.installedOmpVersion == "18.4.8")
        // Graceful: through the bridge, recorded by omp as a normal exit; then resumed from the same file in a new PTY.
        #expect(await fixture.bridge.calls.contains("session.shutdown"))
        #expect(FakeOmp.sessionExits(file) == ["normal"])
        #expect(fixture.omp.lines("argv").last?.contains("--resume \(file)") == true)
        let new = try #require(after.ptyId)
        #expect(new != old.ptyId)
        #expect(await fixture.pool.info(old.ptyId) == nil)
        let screen = screenLines(try await fixture.pool.attach(new, subscriber: UUID()) { _ in })
        let divider = try #require(screen.firstIndex(of: "— terminal restarted —"))
        #expect(screen[..<divider].contains("echo:before-restart"))
        await fixture.finish()
    }

    @Test func whatTheRestartInterruptsIsContinuedWhileAnInterruptionWaitingForTheUserKeepsWaiting() async throws {
        let waiting = Interruption(
            detectedAt: Date(timeIntervalSince1970: 1_790_000_000), cause: "omp exited unexpectedly: signal 9",
            mainInterrupted: false, agents: [InterruptedAgent(id: "Sleeper")])
        let fixture = try await SupervisorFixture(
            bridgeCapabilities: recoveryCapabilities, restorePolicy: RestorePolicy(main: .ask, subagents: .ask))
        try await fixture.supervisor.start(.fresh)
        try await fixture.waitForStatus(.idle)
        try await fixture.manifest.updateEntry(fixture.key) { $0.pendingContinuation = waiting }
        let file = try #require(try await fixture.entry.sessionFile)
        try appendTurnInFlight(to: file, command: "./deploy.sh")
        await fixture.bridge.push("activity", ["state": "busy"], to: fixture.key)
        try await fixture.waitForStatus(.busy)

        try await fixture.supervisor.restart(force: true)
        let prompt = try await eventuallyValue("continuation prompt") {
            await fixture.bridge.requests.first { $0.method == "session.prompt" }?.params["text"]?.stringValue
        }
        #expect(prompt.contains("restarted from Lantern") && prompt.contains("- bash: ./deploy.sh"))
        #expect(try await fixture.entry.pendingContinuation == waiting)
        await fixture.finish()
    }

    @Test func aPinnedOmpThatIsGoneIsReplacedByTheOneANewSessionGets() async throws {
        let temp = try ShortTempDir()
        let located = try InstalledOmp(in: temp, version: "18.4.8")
        let fixture = try await SupervisorFixture(environment: ["OMP_BIN": located.path]) { entry in
            entry.launch.ompPath = "/tmp/od-removed-cellar/omp"
            entry.launch.ompVersion = "18.4.4"
        }
        try await fixture.supervisor.start(.fresh)
        try await fixture.waitForStatus(.idle)
        let entry = try await fixture.entry
        #expect(entry.launch.ompPath == located.path && entry.launch.ompVersion == "18.4.8")
        #expect(try await fixture.pty().command.first == located.path)
        #expect(fixture.notices.value.contains { $0.message.contains("no longer at /tmp/od-removed-cellar/omp") })
        await fixture.finish()
    }
}

@Suite(.timeLimit(.minutes(1)))
struct OmpInstallationsTests {
    @Test func anUpgradeOnDiskReachesTheSessionsPinnedToThatPathWithoutPolling() async throws {
        let temp = try ShortTempDir()
        let omp = try InstalledOmp(in: temp, version: "18.4.4")
        let manifest = ManifestPublisher(store: ManifestStore(url: temp.url.appending(path: "sessions.json")))
        let pinned = { (key: SessionKey, status: SessionStatus) in
            SessionManifestEntry(
                sessionKey: key, workspace: "/", launch: LaunchSpec(ompPath: omp.path, ompVersion: "18.4.4"), status: status,
                createdAt: Date())
        }
        let entries = [pinned("running", .idle), pinned("closed", .closed)]
        try await manifest.update { $0.sessions = entries }
        let installations = OmpInstallations(
            manifest: manifest, locate: { throw OmpBinaryError.notFound(searched: []) }, persistenceFailed: { _ in },
            settle: .milliseconds(100))
        await installations.refresh()
        #expect(await manifest.entry("running")?.installedOmpVersion == "18.4.4")

        // An upgrade replaces the file (as `brew upgrade` re-points its link): the watch reads it again.
        let replacement = temp.url.appending(path: "omp-installed.new").path(percentEncoded: false)
        try FileManager.default.copyItem(atPath: omp.path, toPath: replacement)
        try omp.install("18.4.8")
        #expect(rename(replacement, omp.path) == 0)
        try await eventually("the upgrade is seen") { await manifest.entry("running")?.installedOmpVersion == "18.4.8" }
        let running = try #require(await manifest.entry("running"))
        #expect(running.ompUpgrade == "18.4.8")
        #expect(await manifest.entry("closed")?.ompUpgrade == nil)
    }
}

@Suite struct LowSpaceAlarmTests {
    @Test func warnsOncePerEpisodeAndReArmsOnlyWellAboveTheThreshold() {
        var alarm = LowSpaceAlarm(fixedThreshold: 1000)
        // At the threshold; under it; still low; back above but under 1.5×; hovering under it again; re-armed; low again.
        let readings: [Int64] = [1000, 999, 500, 1400, 990, 1500, 10]
        let warnings = readings.map { alarm.observe(free: $0, volumeBytes: 1 << 40) }
        #expect(warnings == [false, true, false, false, false, false, true])
    }

    @Test func theDefaultThresholdIsOneGiBOrOnePercentWhicheverIsMore() {
        let alarm = LowSpaceAlarm()
        #expect(alarm.threshold(volumeBytes: 50 << 30) == 1 << 30)
        #expect(alarm.threshold(volumeBytes: 500 << 30) == 5 << 30)
    }

    @Test func failedSnapshotPassesWarnOncePerStreak() throws {
        let temp = try ShortTempDir()
        let notices = Box<[DaemonNotice]>([])
        let watch = StorageWatch(volume: temp.url, alarm: LowSpaceAlarm(fixedThreshold: 1)) { notice in
            notices.mutate { $0.append(notice) }
        }
        let full = StorageError.system(operation: "write", path: "/x/.p.json.tmp", code: ENOSPC)
        watch.snapshotsWritten(failure: full)
        watch.snapshotsWritten(failure: full)
        #expect(notices.value.count == 1)
        #expect(notices.value.first?.topic == DaemonNotice.diskSpaceTopic)
        watch.snapshotsWritten(failure: nil)
        watch.snapshotsWritten(failure: StorageError.system(operation: "rename", path: "/x/p.json", code: EACCES))
        #expect(notices.value.count == 2)
        #expect(notices.value.last?.topic == nil, "not about space")
    }
}

@Suite struct OmpGarbageCollectorTests {
    /// `omp gc --json` of omp 18.4.4, a dry run.
    static let dryRun = """
        {
          "agentDir": "/Users/me/.omp/agent", "apply": false, "lockPath": "/Users/me/.omp/agent/gc.lock",
          "blobs": {"referenced": 1567, "candidates": 1573, "wouldDelete": 12, "deleted": 0, "bytes": 1292656, "errors": []},
          "archive": {"scanned": 230, "skippedActive": 36, "keptNewestGlobal": 20, "keptNewestPerCwd": 89, "wouldArchive": 73,
                      "archived": 0, "historyRowsDeleted": 0, "statsRowsDeleted": 0, "ftsRebuilt": false, "errors": []},
          "wal": {"databases": [{"dbPath": "/Users/me/.omp/agent/history.db", "walBytes": 49472, "wouldCheckpoint": true,
                                 "checkpointed": false, "busy": 0, "log": 0, "checkpointedFrames": 0}],
                  "walBytes": 49472, "wouldCheckpoint": true, "checkpointed": false}
        }
        """

    /// `omp gc --json --apply --blobs --wal`: no `archive` section.
    static let applied = """
        {"agentDir": "/tmp/agent", "apply": true, "lockPath": "/tmp/agent/gc.lock",
         "blobs": {"referenced": 0, "candidates": 1, "wouldDelete": 1, "deleted": 1, "bytes": 3000, "errors": ["EACCES blobs/ab"]},
         "wal": {"databases": [], "walBytes": 0, "wouldCheckpoint": true, "checkpointed": true}}
        """

    @Test func aDryRunReportsWhatWouldGoAndTheArchiveCandidates() throws {
        #expect(try OmpGarbageCollector.parse(Self.dryRun) == OmpStorage(
            agentDir: "/Users/me/.omp/agent", blobs: 12, blobBytes: 1_292_656, walBytes: 49472, walCheckpointed: false,
            archiveCandidates: 73))
    }

    @Test func anApplyReportsWhatWentWithoutArchiving() throws {
        #expect(try OmpGarbageCollector.parse("omp: warming up\n" + Self.applied) == OmpStorage(
            agentDir: "/tmp/agent", blobs: 1, blobBytes: 3000, walBytes: 0, walCheckpointed: true, archiveCandidates: nil,
            errors: ["EACCES blobs/ab"]))
    }

    @Test func outputThatIsNoReportIsAnError() {
        #expect(throws: OmpGarbageCollector.Failure.self) { try OmpGarbageCollector.parse("error: unknown command gc") }
        #expect(throws: OmpGarbageCollector.Failure.self) { try OmpGarbageCollector.parse(#"{"apply": false}"#) }
    }

    @Test func oneRunPerAgentDirectoryWithAPinnedOmpThatIsStillThere() throws {
        let temp = try ShortTempDir()
        let pinned = try InstalledOmp(in: temp, version: "18.4.4").path
        let entry = { (key: SessionKey, omp: String, env: [String: String], status: SessionStatus) in
            SessionManifestEntry(
                sessionKey: key, workspace: "/", launch: LaunchSpec(ompPath: omp, ompVersion: "18.4.4", env: env), status: status,
                createdAt: Date())
        }
        let work = ["OMP_PROFILE": "work"]
        let targets = OmpGarbageCollector.targets(
            entries: [
                entry("closed-default", "/gone/omp", [:], .closed), entry("work-1", pinned, work, .closed),
                entry("work-2", "/gone/omp", work, .idle),
            ],
            baseEnvironment: ["HOME": "/Users/me"], located: "/opt/homebrew/bin/omp")
        #expect(targets == [
            OmpGarbageCollector.Target(omp: pinned, environment: ["HOME": "/Users/me", "OMP_PROFILE": "work"]),
            OmpGarbageCollector.Target(omp: "/opt/homebrew/bin/omp", environment: ["HOME": "/Users/me"]),
        ])
        #expect(OmpGarbageCollector.targets(entries: [], baseEnvironment: [:], located: nil).isEmpty)
    }
}

@Suite struct UnreferencedSnapshotTests {
    private static func snapshot(_ id: PTYID, session: SessionKey? = nil) -> PTYSnapshot {
        PTYSnapshot(
            info: PTYInfo(ptyId: id, cwd: "/", command: ["/bin/sh"], cols: 80, rows: 24, pid: nil, running: false, sessionKey: session),
            screen: Data("screen of \(id)".utf8), env: nil, savedAt: Date())
    }

    private static func write(_ text: String, _ name: String, in directory: URL) throws {
        try text.write(to: directory.appending(path: name), atomically: false, encoding: .utf8)
    }

    @Test func onlyFilesNothingWillReadAgainAreUnreferenced() throws {
        let temp = try ShortTempDir()
        let store = PTYSnapshotStore(directory: temp.url.appending(path: "pty", directoryHint: .isDirectory))
        for snapshot in [
            Self.snapshot("live"), Self.snapshot("closed"), Self.snapshot("kept", session: "k"),
            Self.snapshot("forgotten", session: "f"),
        ] {
            try store.write(snapshot)
        }
        let data = try JSONEncoder().encode(Self.snapshot("other"))
        try data.write(to: store.directory.appending(path: "renamed.json"))
        try Self.write("{not json", "corrupt.json", in: store.directory)
        try Self.write("half", ".closed.json.tmp", in: store.directory)
        try Self.write("mine", "notes.txt", in: store.directory)
        try Self.write("finder", ".DS_Store", in: store.directory)

        let names = store.unreferenced(live: ["live"], sessions: ["k"]).map(\.url.lastPathComponent).sorted()
        #expect(names == [".closed.json.tmp", "closed.json", "corrupt.json", "forgotten.json", "renamed.json"])
    }

    @Test func thePoolPrunesNothingBeforeItTookInThePreviousDaemonsSnapshots() async throws {
        let temp = try ShortTempDir()
        let directory = temp.url.appending(path: "pty", directoryHint: .isDirectory)
        let store = PTYSnapshotStore(directory: directory)
        try store.write(Self.snapshot("terminal"))
        try store.write(Self.snapshot("screen", session: "s1"))
        try Self.write("half", ".gone.json.tmp", in: directory)
        let pool = PTYPool(snapshotDirectory: directory, snapshotInterval: .seconds(3600))

        #expect(await pool.unreferencedSnapshots(sessions: []).count == 0)
        _ = try await pool.restoreFromSnapshots()
        // The exited terminal came back and the session's screen waits for its next omp: only the leftover is garbage.
        #expect(await pool.unreferencedSnapshots(sessions: []).count == 1)
        #expect(await pool.removeUnreferencedSnapshots(sessions: []).count == 1)
        let left = try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false)).sorted()
        #expect(left == ["screen.json", "terminal.json"])
        try await pool.shutdown()
    }
}
