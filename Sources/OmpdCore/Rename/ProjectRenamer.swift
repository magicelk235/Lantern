import Darwin
import Foundation
import IDEProtocol
import os

/// The disk side of `project.rename`, between stopping the project's sessions and resuming them: the folder renamed,
/// omp's data moved in every agent directory, the manifest pointed at the new folder. Journaled in
/// `$APP_SUPPORT/project-rename.json` before anything moves, so the next ompd finishes a rename a crash cut short
/// (`recover`), or forgets one that never got to move the folder.
struct ProjectRenamer {
    let journalURL: URL
    let manifest: ManifestPublisher

    struct Journal: Codable, Sendable, Equatable {
        enum Phase: String, Codable, Sendable {
            /// Sessions are being stopped; the folder has not moved (unless a crash came right after).
            case stopping
            /// The folder is at its new path; omp's data and the manifest are to follow.
            case moved
        }

        var paths: ProjectPaths
        var moveFolder: Bool
        var phase: Phase
        /// Each omp agent directory the project's sessions use, with what it needs to move its data.
        var stores: [Store]
    }

    struct Store: Codable, Sendable, Equatable {
        var storage: OmpAgentStorage
        var bankBase: String?
        var databasePath: String?
        /// The old cwds omp has data for there, read before anything moved (the steps rewrite where they come from).
        var cwds: [String]
    }

    /// The agent directories of the base environment and of each session's pinned environment, with their Mnemopi
    /// settings (`settings`) and the cwds omp has data for in each.
    static func stores(
        for entries: [SessionManifestEntry], baseEnvironment: [String: String], paths: ProjectPaths,
        settings: (_ environment: [String: String]) async -> OmpMemorySettings
    ) async -> [Store] {
        var stores: [Store] = []
        var seen = Set<OmpAgentStorage>()
        for environment in [baseEnvironment] + entries.map({ baseEnvironment.merging($0.launch.env) { $1 } }) {
            let storage = OmpAgentStorage(environment: environment)
            guard seen.insert(storage).inserted else { continue }
            let memory = await settings(environment)
            let migration = OmpDataMigration(paths: paths, storage: storage, bankBase: memory.bankBase, databasePath: memory.databasePath)
            stores.append(Store(storage: storage, bankBase: memory.bankBase, databasePath: memory.databasePath, cwds: migration.knownCwds()))
        }
        return stores
    }

    /// The journal, durably, before anything moves.
    func begin(_ journal: Journal) throws {
        try StorageIO.writeAtomically(try IDECoding.encoder().encode(journal), to: journalURL, durable: true)
    }

    /// The rename stopped before the folder moved: nothing is left to finish.
    func abandon() {
        unlink(journalURL.path(percentEncoded: false))
    }

    /// Renames the folder (`moveFolder`), then records that it moved. Fails, with nothing moved, in the Finder's words.
    func moveFolder(_ journal: inout Journal) throws {
        if journal.moveFolder {
            let (from, to) = (journal.paths.canonical.from, journal.paths.canonical.to)
            // A rename that only changes case is the same folder, on a volume that ignores case.
            let sameItem = OmpDataMigration.isSameItem(from, to)
            let renamed = sameItem ? Darwin.rename(from, to) : renamex_np(from, to, UInt32(RENAME_EXCL))
            guard renamed == 0 else { throw DaemonError(.badParams, Self.explanation(errno, to: to)) }
        }
        journal.phase = .moved
        try? begin(journal)
    }

    /// omp's data in every agent directory, then the manifest; the journal goes once both are done. Returns what of
    /// omp's data stayed under the old path. A manifest that cannot be written throws and keeps the journal: the next
    /// ompd finishes the rename.
    func finish(_ journal: Journal) async throws -> [String] {
        var problems: [String] = []
        var sessionFiles: [String: String] = [:]
        for store in journal.stores {
            let migration = OmpDataMigration(
                paths: journal.paths, storage: store.storage, bankBase: store.bankBase, databasePath: store.databasePath)
            let outcome = migration.run(cwds: store.cwds)
            for problem in outcome.problems where !problems.contains(problem) { problems.append(problem) }
            sessionFiles.merge(outcome.sessionFiles) { first, _ in first }
        }
        let paths = journal.paths
        let moved = sessionFiles
        try await manifest.update { Self.rewrite(&$0, paths: paths, sessionFiles: moved) }
        abandon()
        return problems
    }

    /// Every session of the folder or of a folder in it names the new paths: its workspace, its session file (where
    /// the migration moved it, or where it is inside the folder), its `--session-dir` and other paths in its launch,
    /// its services' folders.
    static func rewrite(_ manifest: inout SessionManifest, paths: ProjectPaths, sessionFiles: [String: String]) {
        var moved: [String: String] = [:]
        for (old, new) in sessionFiles {
            for alias in aliases(old) { moved[alias] = new }
        }
        for index in manifest.sessions.indices {
            var entry = manifest.sessions[index]
            let inProject = paths.canonical.contains(entry.workspace) || paths.omp.contains(entry.workspace)
            if let workspace = paths.canonical.moved(entry.workspace) { entry.workspace = workspace }
            if let file = entry.sessionFile {
                entry.sessionFile = aliases(file).lazy.compactMap { moved[$0] }.first ?? paths.moved(file) ?? file
            }
            if inProject {
                entry.launch.sessionDir = entry.launch.sessionDir.map { paths.moved($0) ?? $0 }
                entry.launch.extraArgs = entry.launch.extraArgs.map { paths.moved($0) ?? $0 }
                entry.launch.env = entry.launch.env.mapValues { paths.moved($0) ?? $0 }
                for service in entry.services.indices {
                    entry.services[service].cwd = entry.services[service].cwd.map { paths.moved($0) ?? $0 }
                }
            }
            manifest.sessions[index] = entry
        }
    }

    /// `/private/tmp/x` and `/tmp/x` (and the like) name one file: omp and ompd write either.
    private static func aliases(_ path: String) -> [String] {
        if path.hasPrefix("/private/") { return [path, String(path.dropFirst("/private".count))] }
        if ["/tmp/", "/var/", "/etc/"].contains(where: path.hasPrefix) { return [path, "/private" + path] }
        return [path]
    }

    /// The journal a crashed ompd left, if any.
    static func pending(at url: URL) -> Journal? {
        guard let data = try? StorageIO.readFileIfPresent(url) else { return nil }
        return try? IDECoding.decoder().decode(Journal.self, from: data)
    }

    /// At start, before sessions are restored: a rename the previous ompd left midway is finished when its folder moved
    /// (the sessions then resume at the new path), forgotten when it did not. Returns what stayed under the old path.
    func recover() async -> [String] {
        guard let journal = Self.pending(at: journalURL) else { return [] }
        let (from, to) = (journal.paths.canonical.from, journal.paths.canonical.to)
        let fileManager = FileManager.default
        if journal.phase == .stopping, journal.moveFolder {
            let moved = !fileManager.fileExists(atPath: from) && fileManager.fileExists(atPath: to)
            guard moved else {
                renameLog.notice("the rename of \(from, privacy: .public) never moved the folder; forgetting it")
                abandon()
                return []
            }
        }
        renameLog.notice("finishing the rename of \(from, privacy: .public) to \(to, privacy: .public)")
        do {
            let problems = try await finish(journal)
            for problem in problems { renameLog.error("\(problem, privacy: .public)") }
            return problems
        } catch {
            renameLog.error("the rename of \(from, privacy: .public) could not be finished: \(String(describing: error), privacy: .public)")
            return ["The manifest could not be written: \(error)"]
        }
    }

    /// Why `rename(2)` refused, as the Finder would say it.
    static func explanation(_ code: Int32, to path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return switch code {
        case EEXIST, ENOTEMPTY: "A folder named “\(name)” already exists."
        case EACCES, EPERM: "You don’t have permission to rename this folder."
        case EROFS: "The disk is read-only."
        case ENOSPC: "The disk is full."
        case ENOENT: "The folder is no longer there."
        case EBUSY: "The folder is in use."
        case ENAMETOOLONG: "The name is too long."
        case EXDEV: "The folder can’t be moved to another disk."
        default: String(cString: strerror(code)) + "."
        }
    }
}

/// What omp's settings say about Mnemopi's banks, read with `omp config get … --json` in the environment the project's
/// omp runs with: `mnemopi.bank` (a base name banks are named after) and `mnemopi.dbPath` (moves the banks). Both nil
/// when omp says nothing (unset, or omp could not be asked: the defaults then).
struct OmpMemorySettings: Sendable, Equatable {
    var bankBase: String?
    var databasePath: String?

    static func read(omp: String, environment: [String: String]) async -> OmpMemorySettings {
        async let bank = value("mnemopi.bank", omp: omp, environment: environment)
        async let database = value("mnemopi.dbPath", omp: omp, environment: environment)
        return OmpMemorySettings(bankBase: await bank, databasePath: await database)
    }

    private static func value(_ key: String, omp: String, environment: [String: String]) async -> String? {
        guard let (reason, status, output) = try? await OmpBinary.run(
            omp, arguments: ["config", "get", key, "--json"], environment: environment, timeout: .seconds(10)),
            reason == .exit, status == 0,
            let object = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any],
            let value = object["value"] as? String, !value.isEmpty
        else { return nil }
        return value
    }
}

let renameLog = Logger(subsystem: "com.magicelklabs.lantern.ompd", category: "rename")
