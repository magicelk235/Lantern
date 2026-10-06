import Darwin
import Foundation
import IDEProtocol
import os
import Testing
@testable import OmpdCore

/// End-to-end PTY behaviour with real processes (`/bin/sh`).
@Suite struct PTYPoolTests {
    @Test func commandOutputReachesAttachedClient() async throws {
        try await withFixture { fixture in
            let command = ["/bin/sh", "-c", "printf hello; sleep 5"]
            let info = try await fixture.pool.open(PTYOpen.Params(cwd: fixture.directory, command: command, cols: 80, rows: 24))
            #expect(info.running && info.pid != nil && info.command == command && info.cwd == fixture.directory)
            let client = try await Client.attach(fixture.pool, info.ptyId)
            #expect(try await eventually { client.lines().first == "hello" })
        }
    }

    @Test func interactiveShellEchoesAndResizes() async throws {
        try await withFixture { fixture in
            let info = try await fixture.openShell()
            let client = try await Client.attach(fixture.pool, info.ptyId)
            try await fixture.pool.write(info.ptyId, Data("echo hi\n".utf8))
            #expect(try await eventually { client.lines().contains("hi") })

            try await fixture.pool.resize(info.ptyId, cols: 100, rows: 30)
            try await fixture.pool.write(info.ptyId, Data("stty size\n".utf8))
            #expect(try await eventually { client.lines().contains("30 100") })
            #expect(await fixture.pool.list().map(\.cols) == [100])
        }
    }

    @Test func attachScreenReproducesTheTerminal() async throws {
        try await withFixture { fixture in
            let script = #"sleep 0.5; printf '\033[1;31mRED\033[0m plain \033[38;2;10;20;30;48;5;200mTC\033[0m\n'; i=0; while [ $i -lt 60 ]; do echo "line $i"; i=$((i+1)); done; printf '\033[4mend'; sleep 5"#
            let info = try await fixture.pool.open(PTYOpen.Params(cwd: fixture.directory, command: ["/bin/sh", "-c", script], cols: 40, rows: 10))
            // `raw` receives every byte as the program writes it; `late` only gets the serialized screen.
            let raw = try await Client.attach(fixture.pool, info.ptyId)
            #expect(try await eventually { raw.lines().last { !$0.isEmpty } == "end" })
            let late = try await Client.attach(fixture.pool, info.ptyId)

            let original = raw.replay()
            let restored = late.replay()
            #expect(rowCount(restored.terminal) > 10)
            assertSameState(original, restored)
            let red = restored.terminal.bufferLine(atRow: 0)![0]
            #expect(restored.terminal.getCharacter(for: red) == "R")
            #expect(red.attribute.fg == .ansi256(code: 1) && red.attribute.style.contains(.bold))
            let trueColor = restored.terminal.bufferLine(atRow: 0)![10]
            #expect(trueColor.attribute.fg == .trueColor(red: 10, green: 20, blue: 30) && trueColor.attribute.bg == .ansi256(code: 200))
            #expect(restored.terminal.currentAttribute.style.contains(.underline))
        }
    }

    @Test func detachThenAttachHasNoGapOrDuplicate() async throws {
        try await withFixture { fixture in
            let info = try await fixture.openShell()
            let observer = try await Client.attach(fixture.pool, info.ptyId)
            let first = try await Client.attach(fixture.pool, info.ptyId)
            try await fixture.pool.write(info.ptyId, Data("echo AAA\n".utf8))
            #expect(try await eventually { first.lines().contains("AAA") })

            await fixture.pool.detach(info.ptyId, subscriber: first.id)
            #expect(fixture.snapshotLines(info.ptyId)?.contains("AAA") == true)
            try await fixture.pool.write(info.ptyId, Data("echo BBB\n".utf8))
            #expect(try await eventually { observer.lines().contains("BBB") })

            let second = try await Client.attach(fixture.pool, info.ptyId)
            try await fixture.pool.write(info.ptyId, Data("echo CCC\n".utf8))
            #expect(try await eventually { second.lines().contains("CCC") && observer.lines().contains("CCC") })
            let lines = second.lines()
            for marker in ["AAA", "BBB", "CCC"] {
                #expect(lines.filter { $0 == marker }.count == 1, "\(marker) in \(lines)")
            }
            let upToCCC = { (lines: [String]) in Array(lines.prefix { $0 != "CCC" }) }
            #expect(upToCCC(lines) == upToCCC(observer.lines()))
            #expect(!first.lines().contains("BBB"))
        }
    }

    @Test func snapshotsRestoreScrollbackAndALiveShell() async throws {
        try await withFixture { fixture in
            let info = try await fixture.openShell()
            let client = try await Client.attach(fixture.pool, info.ptyId)
            let subdirectory = fixture.directory + "/sub dir"
            try FileManager.default.createDirectory(atPath: subdirectory, withIntermediateDirectories: true)
            try await fixture.pool.write(info.ptyId, Data("cd 'sub dir'; echo before-restart\n".utf8))
            #expect(try await eventually { client.lines().contains("before-restart") })
            try await fixture.pool.snapshotAll()
            try await fixture.pool.shutdown()
            let oldPID = try #require(info.pid)
            #expect(try await eventually { kill(oldPID, 0) != 0 })

            let pool = PTYPool(snapshotDirectory: fixture.snapshots, snapshotInterval: .seconds(3600))
            let restored = try await pool.restoreFromSnapshots()
            #expect(restored.count == 1)
            let again = try #require(restored.first)
            #expect(again.ptyId == info.ptyId && again.running && again.pid != nil && again.pid != info.pid)
            // The new shell starts where the old one was (`cd` included), same size and command.
            #expect(again.cwd == subdirectory && again.cols == 80 && again.rows == 24 && again.command == info.command)

            let reattached = try await Client.attach(pool, again.ptyId)
            try await pool.write(again.ptyId, Data("pwd\n".utf8))
            #expect(try await eventually { reattached.lines().contains(subdirectory) })
            let lines = reattached.lines()
            let divider = try #require(lines.firstIndex(of: "— terminal restarted —"))
            #expect(lines[..<divider].contains("before-restart"))
            #expect(lines[divider...].contains(subdirectory))
            try await pool.shutdown()
        }
    }

    @Test func closeReapsTheChildAndRemovesTheSnapshot() async throws {
        try await withFixture { fixture in
            let info = try await fixture.pool.open(PTYOpen.Params(cwd: fixture.directory, command: ["/bin/sh", "-c", "printf hello; sleep 5"], cols: 80, rows: 24))
            let pid = try #require(info.pid)
            try await fixture.pool.snapshotAll()
            let snapshot = fixture.snapshots.appendingPathComponent("\(info.ptyId).json").path
            #expect(FileManager.default.fileExists(atPath: snapshot))

            try await fixture.pool.close(info.ptyId)
            // Reaped, not a zombie: the pid no longer exists and is no longer our child.
            #expect(try await eventually { kill(pid, 0) != 0 && errno == ESRCH })
            var status: Int32 = 0
            #expect(waitpid(pid, &status, WNOHANG) == -1 && errno == ECHILD)
            #expect(!FileManager.default.fileExists(atPath: snapshot))
            #expect(await fixture.pool.list().isEmpty)
            await #expect(throws: DaemonError.self) { try await fixture.pool.write(info.ptyId, Data("x".utf8)) }
        }
    }

    @Test func foregroundProcessesAreWhatTheShellRuns() async throws {
        try await withFixture { fixture in
            let info = try await fixture.openShell()
            let client = try await Client.attach(fixture.pool, info.ptyId)
            try await fixture.pool.write(info.ptyId, Data("echo ready\n".utf8))
            #expect(try await eventually { client.lines().contains("ready") })
            #expect(try await fixture.pool.foregroundProcesses(info.ptyId).isEmpty)

            try await fixture.pool.write(info.ptyId, Data("sleep 30 | cat\n".utf8))
            #expect(try await eventually { try await fixture.pool.foregroundProcesses(info.ptyId) == ["sleep", "cat"] })
            try await fixture.pool.write(info.ptyId, Data([0x03])) // ^C
            #expect(try await eventually { try await fixture.pool.foregroundProcesses(info.ptyId).isEmpty })
        }
    }

    @Test func exitedProgramStaysAttachable() async throws {
        try await withFixture { fixture in
            let info = try await fixture.pool.open(PTYOpen.Params(cwd: fixture.directory, command: ["/bin/sh", "-c", "echo bye"], cols: 80, rows: 24))
            #expect(try await eventually { await fixture.pool.list().first?.running == false })
            #expect(await fixture.pool.list().first?.pid == nil)
            let client = try await Client.attach(fixture.pool, info.ptyId)
            #expect(try await eventually { client.lines().first == "bye" })
            try await fixture.pool.write(info.ptyId, Data("ignored\n".utf8))
        }
    }

    @Test func largeInputIsDeliveredCompletely() async throws {
        try await withFixture { fixture in
            // Far more than the tty input queue holds: the rest waits in the pool until the program reads it.
            let info = try await fixture.pool.open(PTYOpen.Params(cwd: fixture.directory, command: ["/bin/sh", "-c", "stty raw -echo; echo ready; exec cat > input.bin"], cols: 80, rows: 24))
            let client = try await Client.attach(fixture.pool, info.ptyId)
            #expect(try await eventually { client.lines().contains("ready") })
            let payload = Data((0..<(1 << 20)).map { UInt8(ascii: "a") + UInt8($0 % 26) })
            try await fixture.pool.write(info.ptyId, payload.prefix(700_000))
            try await fixture.pool.write(info.ptyId, payload.suffix(from: 700_000))
            let path = fixture.directory + "/input.bin"
            #expect(try await eventually { (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) == payload.count })
            #expect(FileManager.default.contents(atPath: path) == payload)
        }
    }

    @Test func queriesAreAnsweredWhileDetached() async throws {
        try await withFixture { fixture in
            // Asks for the cursor position and blocks until the terminal replies; nobody is attached.
            let script = #"stty -icanon -echo; printf 'ab\033[6n'; IFS= read -r -d R reply; printf '\ngot:%s\n' "${reply#?}"; sleep 5"#
            let info = try await fixture.pool.open(PTYOpen.Params(cwd: fixture.directory, command: ["/bin/sh", "-c", script], cols: 80, rows: 24))
            try await Task.sleep(for: .milliseconds(500))
            let client = try await Client.attach(fixture.pool, info.ptyId)
            #expect(try await eventually { client.lines().contains("got:[1;3") })
        }
    }

    @Test func restoredExitedProgramIsNotRerun() async throws {
        try await withFixture { fixture in
            let info = try await fixture.pool.open(PTYOpen.Params(cwd: fixture.directory, command: ["/bin/sh", "-c", "echo run >> runs.txt; echo done"], cols: 80, rows: 24))
            #expect(try await eventually { await fixture.pool.list().first?.running == false })
            try await fixture.pool.shutdown()

            let pool = PTYPool(snapshotDirectory: fixture.snapshots, snapshotInterval: .seconds(3600))
            let restored = try await pool.restoreFromSnapshots()
            #expect(restored.map(\.ptyId) == [info.ptyId])
            #expect(restored.first?.running == false && restored.first?.pid == nil)
            let client = try await Client.attach(pool, info.ptyId)
            #expect(client.lines().contains("done") && !client.lines().contains("— terminal restarted —"))
            try await Task.sleep(for: .milliseconds(200))
            #expect(try String(contentsOfFile: fixture.directory + "/runs.txt", encoding: .utf8) == "run\n")
            try await pool.shutdown()
        }
    }

    @Test func snapshotsAreWrittenAfterChangesOnly() async throws {
        try await withFixture(snapshotInterval: .milliseconds(150)) { fixture in
            let info = try await fixture.pool.open(PTYOpen.Params(cwd: fixture.directory, command: ["/bin/sh", "-c", "printf one; sleep 0.6; printf ' two'; sleep 5"], cols: 80, rows: 24))
            #expect(try await eventually { fixture.snapshotLines(info.ptyId)?.first == "one" })
            #expect(try await eventually { fixture.snapshotLines(info.ptyId)?.first == "one two" })
            let written = try FileManager.default.attributesOfItem(atPath: fixture.snapshotPath(info.ptyId))[.modificationDate] as? Date
            try await Task.sleep(for: .milliseconds(700))
            let idle = try FileManager.default.attributesOfItem(atPath: fixture.snapshotPath(info.ptyId))[.modificationDate] as? Date
            #expect(written != nil && written == idle)
        }
    }

    @Test func childStartsWithCleanProcessState() async throws {
        try await withFixture { fixture in
            // A daemon fd without CLOEXEC and an ignored SIGPIPE must not reach programs in the terminal.
            let stray = open("/dev/null", O_RDONLY)
            defer { close(stray) }
            signal(SIGPIPE, SIG_IGN)
            let script = #"/usr/sbin/lsof -p $$ -a -d 0-255 -F f | grep '^f' | tr '\n' ' ' | sed -e 's/^/fds:/' -e 's/ $//'; echo; yes | head -1 >/dev/null; echo "yes:${PIPESTATUS[0]}"; echo "env:$TERM $COLORTERM $PWD"; sleep 5"#
            let info = try await fixture.pool.open(PTYOpen.Params(cwd: fixture.directory, command: ["/bin/sh", "-c", script], cols: 120, rows: 24))
            let client = try await Client.attach(fixture.pool, info.ptyId)
            #expect(try await eventually { client.lines().contains { $0.hasPrefix("env:") } })
            let lines = client.lines()
            #expect(lines.contains("fds:f0 f1 f2"))
            #expect(lines.contains("yes:141")) // killed by SIGPIPE: default disposition
            #expect(lines.contains("env:xterm-256color truecolor \(fixture.directory)"))
        }
    }

    @Test func closeKillsAProcessGroupThatIgnoresHangup() async throws {
        try await withFixture { fixture in
            let info = try await fixture.pool.open(PTYOpen.Params(cwd: fixture.directory, command: ["/bin/sh", "-c", "trap '' HUP; echo ready; sleep 60"], cols: 80, rows: 24))
            let pid = try #require(info.pid)
            let client = try await Client.attach(fixture.pool, info.ptyId)
            #expect(try await eventually { client.lines().contains("ready") })
            try await fixture.pool.close(info.ptyId)
            try await Task.sleep(for: .seconds(1))
            #expect(kill(pid, 0) == 0) // still inside the grace period
            #expect(try await eventually(timeout: .seconds(8)) { kill(pid, 0) != 0 && errno == ESRCH })
        }
    }

    @Test func defaultCommandIsTheLoginShell() async throws {
        try await withFixture { fixture in
            let info = try await fixture.pool.open(PTYOpen.Params(cwd: fixture.directory, cols: 80, rows: 24))
            let shell = try #require(getpwuid(getuid())?.pointee.pw_shell).map { String(cString: $0) }
            #expect(info.command == [shell, "-l"] && info.running)
            try await fixture.pool.close(info.ptyId)
        }
    }

    @Test func invalidRequestsAreRejected() async throws {
        try await withFixture { fixture in
            let pool = fixture.pool
            let cwd = fixture.directory
            await #expect(throws: DaemonError.self) {
                try await pool.open(PTYOpen.Params(cwd: cwd, command: ["no-such-command-xyz"], cols: 80, rows: 24))
            }
            await #expect(throws: DaemonError.self) {
                try await pool.open(PTYOpen.Params(cwd: cwd + "/missing", command: ["/bin/sh"], cols: 80, rows: 24))
            }
            await #expect(throws: DaemonError.self) {
                try await pool.open(PTYOpen.Params(cwd: cwd, command: ["/bin/sh"], cols: 0, rows: 24))
            }
            await #expect(throws: DaemonError.self) { try await pool.close("nope") }
            #expect(await pool.list().isEmpty)
        }
    }

    // MARK: - Session PTYs

    @Test func sessionPTYIsTaggedAndReportsHowItsProgramEnded() async throws {
        try await withFixture { fixture in
            let exits = Box<[PTYExit]>([])
            let script = #"printf 'env:%s:%s:%s\n' "$FROM_BASE" "$FROM_OVERLAY" "$TERM"; read -r line; exit 7"#
            let info = try await fixture.openSession("s1", ["/bin/sh", "-c", script], base: ["FROM_BASE": "b", "PATH": "/usr/bin:/bin"],
                                                     overlay: ["FROM_OVERLAY": "o"]) { exit in exits.mutate { $0.append(exit) } }
            #expect(info.sessionKey == "s1" && info.running && info.cols == 80 && info.rows == 24)
            #expect(await fixture.pool.list().map(\.sessionKey) == ["s1"])
            let client = try await Client.attach(fixture.pool, info.ptyId)
            #expect(try await eventually { client.lines().contains("env:b:o:xterm-256color") })
            try await fixture.pool.write(info.ptyId, Data("go\n".utf8))
            #expect(try await eventually { exits.value == [PTYExit(code: 7, signal: nil)] })
            #expect(await fixture.pool.info(info.ptyId)?.running == false)

            let killed = try await fixture.openSession("s2", ["/bin/sh", "-c", "exec sleep 30"]) { exit in exits.mutate { $0.append(exit) } }
            try await fixture.pool.signal(killed.ptyId, SIGKILL)
            #expect(try await eventually { exits.value.last == PTYExit(code: nil, signal: SIGKILL) })
            await #expect(throws: DaemonError.self) { try await fixture.pool.close(killed.ptyId, refusingSessions: true) }
            try await fixture.pool.close(killed.ptyId)
            #expect(await fixture.pool.list().map(\.sessionKey) == ["s1"])
        }
    }

    @Test func respawnedSessionKeepsTheOldScreenAboveTheDividerDespiteTheNewProgramsClear() async throws {
        try await withFixture { fixture in
            let old = try await fixture.openSession("s1", ["/bin/sh", "-c", "echo old-output; sleep 30"])
            let watcher = try await Client.attach(fixture.pool, old.ptyId)
            #expect(try await eventually { watcher.lines().contains("old-output") })
            try await fixture.pool.signal(old.ptyId, SIGKILL)
            #expect(try await eventually { await fixture.pool.info(old.ptyId)?.running == false })

            // omp's TUI starts with ESC[H ESC[2J ESC[3J (clear screen and scrollback); here split across two writes.
            let script = #"printf '\033[H\033[2J\033['; sleep 0.2; printf '3Jfresh\n'; read -r x; printf '\033[3Jafter-second-erase\n'; sleep 30"#
            let new = try await fixture.openSession("s1", ["/bin/sh", "-c", script], cols: 100, rows: 30, continuing: old.ptyId)
            #expect(new.ptyId != old.ptyId && new.cols == 100 && new.rows == 30)
            #expect(await fixture.pool.info(old.ptyId) != nil, "the caller closes the previous PTY")
            let client = try await Client.attach(fixture.pool, new.ptyId)
            #expect(try await eventually { client.lines().contains("fresh") })
            let lines = client.lines()
            let divider = try #require(lines.firstIndex(of: "— terminal restarted —"))
            #expect(lines[..<divider].contains("old-output"))
            #expect(lines[divider...].contains("fresh"))
            #expect(Client.fromScreen(try await fixture.pool.attach(new.ptyId, subscriber: UUID()) { _ in }).lines() == lines)

            // Only the first erase is dropped: a later one clears the scrollback as usual.
            try await fixture.pool.write(new.ptyId, Data("go\n".utf8))
            #expect(try await eventually { client.lines().contains("after-second-erase") })
            #expect(!client.lines().contains("old-output"))
        }
    }

    @Test func theDividerGoesBelowEverythingTheOldProgramLeftUnderItsCursor() async throws {
        try await withFixture { fixture in
            // A TUI that died with its cursor mid-screen and a dialog drawn below it (omp waiting on an approval).
            let dialog = #"printf 'prompt> \n\n\ndialog-top\ndialog-bottom\033[2;9H'; sleep 30"#
            let old = try await fixture.openSession("s1", ["/bin/sh", "-c", dialog])
            let watcher = try await Client.attach(fixture.pool, old.ptyId)
            #expect(try await eventually { watcher.lines().contains("dialog-bottom") })
            try await fixture.pool.signal(old.ptyId, SIGKILL)
            #expect(try await eventually { await fixture.pool.info(old.ptyId)?.running == false })

            // The new TUI paints over its whole screen from the top, as omp's does.
            let repaint = #"printf '\033[H\033[2J\033[3J'; i=0; while [ $i -lt 24 ]; do printf 'new-row\n'; i=$((i+1)); done; sleep 30"#
            let new = try await fixture.openSession("s1", ["/bin/sh", "-c", repaint], continuing: old.ptyId)
            let client = try await Client.attach(fixture.pool, new.ptyId)
            #expect(try await eventually { client.lines().filter { $0 == "new-row" }.count == 24 })
            let lines = client.lines()
            let divider = try #require(lines.firstIndex(of: "— terminal restarted —"), "the divider survives: \(lines)")
            #expect(lines[..<divider].contains("dialog-bottom"), "the whole old screen is above it")
            #expect(!lines[divider...].contains("dialog-bottom"))
        }
    }

    @Test func sessionScreensOutliveTheDaemonButNotTheirSessions() async throws {
        try await withFixture { fixture in
            let kept = try await fixture.openSession("kept", ["/bin/sh", "-c", "echo before-restart; sleep 30"])
            let gone = try await fixture.openSession("gone", ["/bin/sh", "-c", "echo other; sleep 30"])
            let client = try await Client.attach(fixture.pool, kept.ptyId)
            #expect(try await eventually { client.lines().contains("before-restart") })
            try await fixture.pool.shutdown()
            #expect(FileManager.default.fileExists(atPath: fixture.snapshotPath(kept.ptyId)))

            let pool = PTYPool(snapshotDirectory: fixture.snapshots, snapshotInterval: .seconds(3600))
            #expect(try await pool.restoreFromSnapshots().isEmpty, "sessions are respawned by their supervisors")
            await pool.discardSessionScreens(keeping: ["kept"])
            #expect(!FileManager.default.fileExists(atPath: fixture.snapshotPath(gone.ptyId)))
            let respawned = try await pool.openSession(
                sessionKey: "kept", cwd: fixture.directory, command: ["/bin/sh", "-c", "echo after-restart; sleep 30"],
                environment: ProcessInfo.processInfo.environment, overlay: [:], cols: nil, rows: nil, continuing: nil, onExit: { _ in })
            #expect(respawned.cols == kept.cols && respawned.rows == kept.rows)
            #expect(!FileManager.default.fileExists(atPath: fixture.snapshotPath(kept.ptyId)), "taken over by the new PTY")
            let reattached = try await Client.attach(pool, respawned.ptyId)
            #expect(try await eventually { reattached.lines().contains("after-restart") })
            let lines = reattached.lines()
            let divider = try #require(lines.firstIndex(of: "— terminal restarted —"))
            #expect(lines[..<divider].contains("before-restart"))
            try await pool.shutdown()
        }
    }

    @Test func everyChangeOfThePTYListIsPublished() async throws {
        try await withFixture { fixture in
            let published = Box<[[PTYInfo]]>([])
            await fixture.pool.setChangeHandler { list in published.mutate { $0.append(list) } }
            let terminal = try await fixture.pool.open(PTYOpen.Params(cwd: fixture.directory, command: ["/bin/sh", "-c", "read -r x"], cols: 80, rows: 24))
            #expect(published.value.last?.map(\.ptyId) == [terminal.ptyId])
            try await fixture.pool.resize(terminal.ptyId, cols: 90, rows: 20)
            #expect(published.value.last?.first?.cols == 90 && published.value.last?.first?.rows == 20)
            let session = try await fixture.openSession("s1", ["/bin/sh", "-c", "exit 0"])
            #expect(try await eventually { published.value.last?.last == PTYInfo(
                ptyId: session.ptyId, cwd: fixture.directory, command: session.command, cols: 80, rows: 24, pid: nil, running: false,
                sessionKey: "s1") })
            try await fixture.pool.close(terminal.ptyId)
            #expect(published.value.last?.map(\.ptyId) == [session.ptyId])
        }
    }

    @Test func scrollbackEraseFilterDropsOnlyTheFirstSequenceAcrossChunkBoundaries() {
        let stream = Array("a\u{1b}[3Jb\u{1b}[3Jc".utf8)
        for split in 0...stream.count {
            var filter = ScrollbackEraseFilter()
            var out = stream[..<split].withUnsafeBufferPointer { filter.filter($0) }
            out += stream[split...].withUnsafeBufferPointer { filter.filter($0) }
            out += filter.remainder()
            #expect(String(decoding: out, as: UTF8.self) == "ab\u{1b}[3Jc", "split at \(split)")
        }
        var filter = ScrollbackEraseFilter()
        let partial = Array("x\u{1b}[".utf8)
        #expect(partial.withUnsafeBufferPointer { filter.filter($0) } == Array("x".utf8))
        #expect(filter.remainder() == Array("\u{1b}[".utf8), "an unfinished sequence is delivered at the end")
    }
}

// MARK: - Fixtures

/// A pool with its own temporary working and snapshot directories.
private struct Fixture {
    let base: URL
    /// Physical path (no symlinks), as the pool reports it after tracking the shell's directory.
    let directory: String
    let snapshots: URL
    let pool: PTYPool

    init(snapshotInterval: Duration = .seconds(3600)) throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("pty-tests-\(UUID().uuidString)")
        let cwd = base.appendingPathComponent("cwd")
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        let resolved = try #require(realpath(cwd.path, nil))
        directory = String(cString: resolved)
        free(resolved)
        snapshots = base.appendingPathComponent("snapshots")
        pool = PTYPool(snapshotDirectory: snapshots, snapshotInterval: snapshotInterval)
    }

    func snapshotPath(_ id: PTYID) -> String {
        snapshots.appendingPathComponent("\(id).json").path
    }

    /// Text of the snapshot on disk, replayed into a fresh terminal.
    func snapshotLines(_ id: PTYID) -> [String]? {
        guard let data = FileManager.default.contents(atPath: snapshotPath(id)),
              let snapshot = try? JSONDecoder().decode(PTYSnapshot.self, from: data) else { return nil }
        let mirror = TerminalMirror(cols: snapshot.info.cols, rows: snapshot.info.rows)
        mirror.feed([UInt8](snapshot.screen))
        return bufferText(mirror.terminal)
    }

    func openShell() async throws -> PTYInfo {
        try await pool.open(PTYOpen.Params(cwd: directory, command: ["/bin/sh"], env: ["PS1": "$ ", "ENV": "/dev/null"], cols: 80, rows: 24))
    }

    func openSession(
        _ key: SessionKey, _ command: [String], base: [String: String] = ProcessInfo.processInfo.environment,
        overlay: [String: String] = [:], cols: Int? = nil, rows: Int? = nil, continuing: PTYID? = nil,
        onExit: @escaping @Sendable (PTYExit) -> Void = { _ in }
    ) async throws -> PTYInfo {
        try await pool.openSession(
            sessionKey: key, cwd: directory, command: command, environment: base, overlay: overlay,
            cols: cols ?? (continuing == nil ? 80 : nil), rows: rows ?? (continuing == nil ? 24 : nil), continuing: continuing,
            onExit: onExit)
    }
}

private func withFixture(snapshotInterval: Duration = .seconds(3600), _ body: (Fixture) async throws -> Void) async throws {
    let fixture = try Fixture(snapshotInterval: snapshotInterval)
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    do {
        try await body(fixture)
    } catch {
        try? await fixture.pool.shutdown()
        throw error
    }
    try await fixture.pool.shutdown()
}

/// One subscription: the attach screen plus everything delivered live afterwards.
private final class Client: Sendable {
    let id: UUID
    let screen: Data
    let cols: Int
    let rows: Int
    private let live: OSAllocatedUnfairLock<Data>

    private init(id: UUID, screen: Data, cols: Int, rows: Int, live: OSAllocatedUnfairLock<Data>) {
        self.id = id
        self.screen = screen
        self.cols = cols
        self.rows = rows
        self.live = live
    }

    static func attach(_ pool: PTYPool, _ ptyId: PTYID) async throws -> Client {
        let id = UUID()
        let live = OSAllocatedUnfairLock(initialState: Data())
        let result = try await pool.attach(ptyId, subscriber: id) { chunk in live.withLock { $0.append(chunk) } }
        return Client(id: id, screen: result.screen, cols: result.info.cols, rows: result.info.rows, live: live)
    }

    /// The attach screen alone: what a client attaching now starts from.
    static func fromScreen(_ result: PTYAttach.Result) -> Client {
        Client(id: UUID(), screen: result.screen, cols: result.info.cols, rows: result.info.rows, live: OSAllocatedUnfairLock(initialState: Data()))
    }

    /// A fresh terminal fed with the attach screen and the live output received so far.
    func replay() -> TerminalMirror {
        let mirror = TerminalMirror(cols: cols, rows: rows)
        mirror.feed([UInt8](screen))
        mirror.feed([UInt8](live.withLock { $0 }))
        return mirror
    }

    /// Logical lines (soft-wrapped rows joined), trailing blanks trimmed.
    func lines() -> [String] {
        let terminal = replay().terminal
        var lines: [String] = []
        for (row, text) in bufferText(terminal).enumerated() {
            if row > 0, terminal.bufferLine(atRow: row)!.isWrapped {
                lines[lines.count - 1] += text
            } else {
                lines.append(text)
            }
        }
        return lines
    }
}

/// Polls `condition` until it holds or `timeout` elapses.
private func eventually(timeout: Duration = .seconds(10), _ condition: () async throws -> Bool) async throws -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if try await condition() { return true }
        try await Task.sleep(for: .milliseconds(25))
    }
    return try await condition()
}
