import Foundation
import IDEProtocol
@testable import OmpdCore
import Testing

/// An omp agent directory of its own (`PI_CODING_AGENT_DIR`) with a home folder under /tmp, laid out the way omp 18
/// leaves it, and a project folder `src/app` in that home renamed to `src/web`.
private struct OmpStore {
    let temp: ShortTempDir
    /// Canonical (`/private/tmp/…`).
    let root: String
    let home: String
    let agent: String
    let old: String
    let new: String

    init() throws {
        temp = try ShortTempDir()
        root = OmpAgentStorage.canonical(temp.path)
        home = root + "/home"
        agent = root + "/agent"
        old = home + "/src/app"
        new = home + "/src/web"
        try FileManager.default.createDirectory(atPath: old + "/docs", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: root + "/T", withIntermediateDirectories: true)
    }

    /// The folder as omp names it in what it writes: `/tmp/…`.
    func omp(_ canonical: String) -> String { String(canonical.dropFirst("/private".count)) }

    var storage: OmpAgentStorage {
        OmpAgentStorage(environment: ["HOME": omp(home), "TMPDIR": root + "/T", "PI_CODING_AGENT_DIR": agent])
    }

    /// The folder renamed on disk, and the paths a migration then works with.
    func rename() throws -> ProjectPaths {
        let ompOld = OmpPaths.ompCwd(old)
        try FileManager.default.moveItem(atPath: old, toPath: new)
        return ProjectPaths(canonical: FolderMove(from: old, to: new), omp: FolderMove(from: ompOld, to: OmpPaths.ompCwd(new)))
    }

    func write(_ path: String, _ lines: [String]) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: URL(filePath: path))
    }

    func lines(_ path: String) throws -> [String] {
        try String(contentsOfFile: path, encoding: .utf8).components(separatedBy: "\n")
    }

    func header(_ path: String) throws -> [String: Any] {
        let line = try lines(path).first { $0.contains(#""type":"session""#) } ?? ""
        return try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] ?? [:]
    }

    func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }

    func sqlite(_ path: String, _ sql: String) throws {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/sqlite3")
        process.arguments = [path, sql]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    func query(_ path: String, _ sql: String) throws -> [String] {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(filePath: "/usr/bin/sqlite3")
        process.arguments = [path, sql]
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(separator: "\n").map(String.init)
    }
}

private let slot = #"{"type":"title","v":1,"title":"Fix the build","source":"auto","updatedAt":"2026-10-01T10:00:00.000Z","pad":"      "}"#

private func header(id: String, cwd: String, parent: String? = nil, extra: String = "") -> String {
    let parent = parent.map { #","parentSession":"\#($0)""# } ?? ""
    return #"{"type":"session","version":3,"id":"\#(id)","timestamp":"2026-10-01T10:00:00.000Z","cwd":"\#(cwd)"\#(parent)\#(extra)}"#
}

private let message = #"{"type":"message","id":"m1","parentId":null,"timestamp":"2026-10-01T10:00:01.000Z","message":{"role":"user","content":"in /tmp/x"}}"#

@Suite struct OmpDataMigrationTests {
    @Test func sessionFilesMoveWithTheirSubagentsAndBackupsAndTheirHeadersNameTheNewFolder() throws {
        let store = try OmpStore()
        let sessions = store.agent + "/sessions"
        let main = sessions + "/-src-app/2026-10-01T10-00-00-000Z_a.jsonl"
        let sub = sessions + "/-src-app/2026-10-01T10-00-00-000Z_a/Sub.jsonl"
        try store.write(main, [slot, header(id: "a", cwd: store.omp(store.old), extra: #","additionalDirectories":["\#(store.omp(store.old))/docs"]"#), message])
        try store.write(sub, [header(id: "s", cwd: store.omp(store.old), parent: main), message])
        try store.write(sessions + "/-src-app/2026-10-01T10-00-00-000Z_a/0.read.log", ["output"])
        try store.write(main + ".1790000000.bak", ["backup"])
        let docs = sessions + "/-src-app-docs/2026-10-02T10-00-00-000Z_b.jsonl"
        try store.write(docs, [header(id: "b", cwd: store.omp(store.old) + "/docs"), message])
        // Another project whose session folder's name starts the same way.
        let cli = sessions + "/-src-app-cli/2026-10-03T10-00-00-000Z_c.jsonl"
        try store.write(cli, [header(id: "c", cwd: store.omp(store.home) + "/src/app-cli"), message])
        let modified = Date(timeIntervalSince1970: 1_790_000_000)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: main)

        let paths = try store.rename()
        let migration = OmpDataMigration(paths: paths, storage: store.storage)
        let outcome = migration.run(cwds: migration.knownCwds())

        #expect(outcome.problems.isEmpty)
        let moved = sessions + "/-src-web/2026-10-01T10-00-00-000Z_a.jsonl"
        #expect(outcome.sessionFiles[main] == moved)
        #expect(!store.exists(sessions + "/-src-app") && !store.exists(sessions + "/-src-app-docs"), "nothing left under the old name")
        let lines = try store.lines(moved)
        #expect(lines[0] == slot, "omp rewrites its title slot in place: it keeps its bytes")
        #expect(lines[2] == message, "the conversation is a record: untouched")
        let rewritten = try store.header(moved)
        #expect(rewritten["cwd"] as? String == store.omp(store.new))
        #expect(rewritten["previousSessionFiles"] as? [String] == [main])
        #expect(rewritten["additionalDirectories"] as? [String] == [store.omp(store.new) + "/docs"])
        #expect(lines[1].hasPrefix(#"{"type":"session","version":3,"id":"a""#), "the header keeps its members' order")
        #expect(try FileManager.default.attributesOfItem(atPath: moved)[.modificationDate] as? Date == modified, "resume pickers sort by it")
        let subagent = try store.header(sessions + "/-src-web/2026-10-01T10-00-00-000Z_a/Sub.jsonl")
        #expect(subagent["cwd"] as? String == store.omp(store.new))
        #expect(subagent["parentSession"] as? String == moved)
        #expect(store.exists(sessions + "/-src-web/2026-10-01T10-00-00-000Z_a/0.read.log"))
        #expect(store.exists(moved + ".1790000000.bak"))
        #expect(try store.header(sessions + "/-src-web-docs/2026-10-02T10-00-00-000Z_b.jsonl")["cwd"] as? String == store.omp(store.new) + "/docs")
        #expect(try store.header(cli)["cwd"] as? String == store.omp(store.home) + "/src/app-cli", "another project stays")
    }

    @Test func memoryBanksPromptHistoryAndRecordsFollowTheFolder() throws {
        let store = try OmpStore()
        let ompOld = store.omp(store.old)
        let banks = store.agent + "/memories/mnemopi/banks"
        let oldBank = banks + "/" + OmpPaths.memoryBank(cwd: ompOld, base: nil)
        let oldDocsBank = banks + "/" + OmpPaths.memoryBank(cwd: ompOld + "/docs", base: nil)
        try store.write(oldBank + "/mnemopi.db", ["db"])
        try store.write(oldDocsBank + "/mnemopi.db", ["db"])
        let history = store.agent + "/history.db"
        try store.sqlite(history, """
            CREATE TABLE history (id INTEGER PRIMARY KEY, prompt TEXT NOT NULL UNIQUE, cwd TEXT, session_id TEXT);
            CREATE TABLE session_recaps (id INTEGER PRIMARY KEY, session_id TEXT NOT NULL, cwd TEXT NOT NULL, recap TEXT NOT NULL);
            INSERT INTO history (prompt, cwd) VALUES ('one', '\(ompOld)'), ('two', '\(ompOld)/docs'), ('three', '\(ompOld)-cli'), ('four', NULL);
            INSERT INTO session_recaps (session_id, cwd, recap) VALUES ('a', '\(ompOld)', 'did it');
            """)
        let terminal = store.agent + "/terminal-sessions/ttys001"
        let sessionFile = store.agent + "/sessions/-src-app/2026_a.jsonl"
        try store.write(terminal, [ompOld, sessionFile, "cwdstat 16777229 28962164"])
        let inside = store.old + "/.sessions/2026_d.jsonl"
        let record = store.agent + "/custom-session-files/" + OmpPaths.customSessionRecordName(sessionFile: inside)
        try FileManager.default.createDirectory(atPath: store.agent + "/custom-session-files", withIntermediateDirectories: true)
        try Data(inside.utf8).write(to: URL(filePath: record))
        let composer = store.agent + "/cache/composer.db"
        try FileManager.default.createDirectory(atPath: store.agent + "/cache", withIntermediateDirectories: true)
        try store.sqlite(composer, """
            CREATE TABLE entries (project TEXT NOT NULL, kind TEXT NOT NULL, value TEXT NOT NULL, PRIMARY KEY (project, kind)) WITHOUT ROWID;
            INSERT INTO entries VALUES ('\(ompOld)', 'status', 'old'), ('', 'status', 'global');
            """)

        let paths = try store.rename()
        let migration = OmpDataMigration(paths: paths, storage: store.storage)
        let outcome = migration.run(cwds: migration.knownCwds())

        #expect(outcome.problems.isEmpty)
        let ompNew = store.omp(store.new)
        #expect(!store.exists(oldBank) && store.exists(banks + "/" + OmpPaths.memoryBank(cwd: ompNew, base: nil) + "/mnemopi.db"))
        #expect(!store.exists(oldDocsBank) && store.exists(banks + "/" + OmpPaths.memoryBank(cwd: ompNew + "/docs", base: nil)))
        #expect(try store.query(history, "SELECT prompt || '|' || ifnull(cwd, '') FROM history ORDER BY id") == [
            "one|\(ompNew)", "two|\(ompNew)/docs", "three|\(ompOld)-cli", "four|",
        ])
        #expect(try store.query(history, "SELECT cwd FROM session_recaps") == [ompNew])
        #expect(try store.lines(terminal) == [ompNew, store.agent + "/sessions/-src-web/2026_a.jsonl", "cwdstat 16777229 28962164", ""])
        let movedInside = store.new + "/.sessions/2026_d.jsonl"
        #expect(!store.exists(record))
        #expect(try String(contentsOfFile: store.agent + "/custom-session-files/" + OmpPaths.customSessionRecordName(sessionFile: movedInside), encoding: .utf8) == movedInside)
        #expect(try store.query(composer, "SELECT project || '|' || value FROM entries ORDER BY project") == ["|global", "\(ompNew)|old"])
    }

    @Test func aSecondRunFinishesWhatACrashLeftAndThenChangesNothing() throws {
        let store = try OmpStore()
        let sessions = store.agent + "/sessions"
        let original = sessions + "/-src-app/2026_a.jsonl"
        // Cut short between moving the file and rewriting its header.
        let moved = sessions + "/-src-web/2026_a.jsonl"
        try store.write(moved, [slot, header(id: "a", cwd: store.omp(store.old)), message])
        let paths = try store.rename()
        let migration = OmpDataMigration(paths: paths, storage: store.storage)

        let first = migration.run(cwds: migration.knownCwds())
        #expect(first.problems.isEmpty)
        #expect(first.sessionFiles == [original: moved])
        #expect(try store.header(moved)["cwd"] as? String == store.omp(store.new))
        #expect(try store.header(moved)["previousSessionFiles"] as? [String] == [original])
        let after = try store.lines(moved)

        let second = migration.run(cwds: migration.knownCwds())
        #expect(second == OmpDataMigration.Outcome())
        #expect(try store.lines(moved) == after)
    }

    @Test func whatTheNewNameHasAlreadyStaysAndIsNamed() throws {
        let store = try OmpStore()
        let sessions = store.agent + "/sessions"
        let banks = store.agent + "/memories/mnemopi/banks"
        try store.write(banks + "/" + OmpPaths.memoryBank(cwd: store.omp(store.old), base: "team") + "/mnemopi.db", ["old"])
        try store.write(banks + "/" + OmpPaths.memoryBank(cwd: store.omp(store.new), base: "team") + "/mnemopi.db", ["new"])
        try store.write(sessions + "/-src-app/2026_a.jsonl", [header(id: "a", cwd: store.omp(store.old))])
        try store.write(sessions + "/-src-web/2026_a.jsonl", [header(id: "other", cwd: store.omp(store.new))])
        let paths = try store.rename()
        var migration = OmpDataMigration(paths: paths, storage: store.storage)
        migration.bankBase = "team"

        let outcome = migration.run(cwds: migration.knownCwds())

        #expect(outcome.problems == [
            "omp’s memory of “app” stayed under the old name: “web” already has memory of its own.",
            "An omp session of “app” stayed in the old folder’s list: “2026_a.jsonl” (one of the same name is already there).",
        ])
        #expect(try store.header(sessions + "/-src-web/2026_a.jsonl")["id"] as? String == "other")
        #expect(try store.header(sessions + "/-src-app/2026_a.jsonl")["cwd"] as? String == store.omp(store.old))
    }

    @Test func agentDirectoriesFollowOmpsEnvironment() {
        let profile = OmpAgentStorage(environment: ["HOME": "/Users/u", "OMP_PROFILE": "work", "PI_CODING_AGENT_DIR": "/elsewhere"])
        #expect(profile.agentDir == "/Users/u/.omp/profiles/work/agent", "a profile wins over PI_CODING_AGENT_DIR")
        #expect(profile.sessions == "/Users/u/.omp/profiles/work/agent/sessions")
        let override = OmpAgentStorage(environment: ["HOME": "/Users/u", "PI_CODING_AGENT_DIR": "/tmp/a"])
        #expect(override.agentDir == "/tmp/a" && override.historyDB == "/tmp/a/history.db")
        #expect(override.memoryBanks(databasePath: nil) == "/tmp/a/memories/mnemopi/banks")
        #expect(override.memoryBanks(databasePath: "/tmp/m/x.db") == "/tmp/m/banks")
        let plain = OmpAgentStorage(environment: ["HOME": "/Users/u", "OMP_PROFILE": "Bad Name"])
        #expect(plain.agentDir == "/Users/u/.omp/agent")
        #expect(plain.composerDB == "/Users/u/.omp/agent/cache/composer.db")
        #expect(OmpAgentStorage(environment: ["HOME": "/Users/u", "PI_CONFIG_DIR": ".pi"]).agentDir == "/Users/u/.pi/agent")
    }
}
