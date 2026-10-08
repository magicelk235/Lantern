import Foundation
import IDEProtocol
import IDETransport
import Testing

@testable import OmpdCore

/// `project.rename` end to end through the real `IDEServer`/`IDEClient`, with the fake omp and an omp agent directory
/// of the test's own.
@Suite(.timeLimit(.minutes(2)))
struct ProjectRenameTests {
    /// omp's data for the fixture's workspace: a session file and a memory bank, where omp keeps them.
    private func seedOmpData(_ fixture: DaemonFixture, workspace project: String? = nil) throws -> (storage: OmpAgentStorage, workspace: String) {
        let storage = OmpAgentStorage(environment: fixture.daemon.configuration.baseEnvironment)
        let workspace = try Daemon.canonicalDirectory(project ?? fixture.workspace)
        let folder = storage.sessionDirectory(canonicalCwd: workspace)
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let header = #"{"type":"session","version":3,"id":"a","timestamp":"2026-10-01T10:00:00.000Z","cwd":"\#(OmpPaths.ompCwd(workspace))"}"#
        try Data((header + "\n").utf8).write(to: URL(filePath: folder + "/2026_a.jsonl"))
        let bank = storage.memoryBanks(databasePath: nil) + "/" + OmpPaths.memoryBank(cwd: OmpPaths.ompCwd(workspace), base: nil)
        try FileManager.default.createDirectory(atPath: bank, withIntermediateDirectories: true)
        return (storage, workspace)
    }

    private func headerCwd(_ path: String) throws -> String? {
        let line = try String(contentsOfFile: path, encoding: .utf8).components(separatedBy: "\n")[0]
        return (try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])?["cwd"] as? String
    }

    @Test func aRenameStopsTheSessionMovesTheFolderAndItsOmpDataAndResumesTheSessionThere() async throws {
        let fixture = try await DaemonFixture(isolatedAgent: true)
        let connected = try await fixture.client()
        let entry = try await fixture.createSession(connected)
        try await connected.waitForStatus(entry.sessionKey, .idle)
        let file = try #require(try await connected.entry(entry.sessionKey).sessionFile)
        let (storage, workspace) = try seedOmpData(fixture)

        let target = fixture.temp.path + "/renamed"
        let result = try await connected.client.call(ProjectRename.self, .init(from: workspace, to: target))

        let renamed = try Daemon.canonicalDirectory(target)
        #expect(result == ProjectRename.Result(workspace: renamed, resumed: [entry.sessionKey], notMoved: []))
        #expect(!FileManager.default.fileExists(atPath: workspace))
        #expect(fixture.omp.lines("events").contains("graceful"), "stopped the graceful way")
        try await connected.waitForStatus(entry.sessionKey, .idle)
        #expect(try await connected.entry(entry.sessionKey).workspace == renamed)
        #expect(fixture.omp.lines("argv").last?.contains("--resume \(file)") == true, "resumed with its conversation")
        let moved = storage.sessionDirectory(canonicalCwd: renamed) + "/2026_a.jsonl"
        #expect(try headerCwd(moved) == OmpPaths.ompCwd(renamed))
        #expect(!FileManager.default.fileExists(atPath: storage.sessionDirectory(canonicalCwd: workspace)))
        let banks = storage.memoryBanks(databasePath: nil)
        #expect(FileManager.default.fileExists(atPath: banks + "/" + OmpPaths.memoryBank(cwd: OmpPaths.ompCwd(renamed), base: nil)))
        #expect(!FileManager.default.fileExists(atPath: banks + "/" + OmpPaths.memoryBank(cwd: OmpPaths.ompCwd(workspace), base: nil)))
        #expect(!FileManager.default.fileExists(atPath: fixture.paths.projectRename.path(percentEncoded: false)), "the journal is gone")
        #expect(try fixture.manifestOnDisk().sessions.map(\.workspace) == [renamed])
    }

    @Test func aTakenNameLeavesEverythingAsItWas() async throws {
        let fixture = try await DaemonFixture(isolatedAgent: true)
        let connected = try await fixture.client()
        let entry = try await fixture.createSession(connected)
        try await connected.waitForStatus(entry.sessionKey, .idle)
        let workspace = try Daemon.canonicalDirectory(fixture.workspace)
        let taken = try fixture.temp.directory("taken")

        let refused = await #expect(throws: DaemonError.self) {
            try await connected.client.call(ProjectRename.self, .init(from: workspace, to: taken))
        }

        #expect(refused == DaemonError(.badParams, "A folder named “taken” already exists."))
        #expect(FileManager.default.fileExists(atPath: workspace))
        #expect(try await connected.entry(entry.sessionKey).workspace == workspace)
        #expect(try await connected.entry(entry.sessionKey).status == .idle, "nothing was stopped")
        #expect(!FileManager.default.fileExists(atPath: fixture.paths.projectRename.path(percentEncoded: false)))
    }

    @Test func theNextDaemonFinishesARenameACrashCutShortAfterTheFolderMoved() async throws {
        let fixture = try await DaemonFixture(isolatedAgent: true)
        let connected = try await fixture.client()
        // Not the fixture's own workspace, which a restarted fixture makes again.
        let project = try fixture.temp.directory("project")
        let entry = try await connected.client.call(SessionCreate.self, .init(workspace: project, cols: 100, rows: 30))
        try await connected.waitForStatus(entry.sessionKey, .idle)
        let (storage, workspace) = try seedOmpData(fixture, workspace: project)

        // The journal written, the folder renamed, then the crash.
        let target = (fixture.temp.path as NSString).appendingPathComponent("renamed")
        let paths = try Daemon.renamePaths(.init(from: workspace, to: target))
        let migration = OmpDataMigration(paths: paths, storage: storage)
        let journal = ProjectRenamer.Journal(
            paths: paths, moveFolder: true, phase: .stopping,
            stores: [ProjectRenamer.Store(storage: storage, cwds: migration.knownCwds())])
        try ProjectRenamer(journalURL: fixture.paths.projectRename, manifest: ManifestPublisher(store: ManifestStore(url: fixture.paths.manifest)))
            .begin(journal)
        try FileManager.default.moveItem(atPath: workspace, toPath: target)

        let restarted = try await fixture.restarted()

        let renamed = try Daemon.canonicalDirectory(target)
        #expect(try restarted.manifestOnDisk().sessions.map(\.workspace) == [renamed])
        #expect(try headerCwd(storage.sessionDirectory(canonicalCwd: renamed) + "/2026_a.jsonl") == OmpPaths.ompCwd(renamed))
        #expect(!FileManager.default.fileExists(atPath: fixture.paths.projectRename.path(percentEncoded: false)))
        await restarted.daemon.restore()
        let client = try await restarted.client()
        try await client.waitForStatus(entry.sessionKey, .idle)
        await client.close()
        await restarted.daemon.shutdown()
    }
}
