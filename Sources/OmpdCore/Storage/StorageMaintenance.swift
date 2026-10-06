import Foundation
import IDEProtocol

/// `storage.report` and `storage.clean`: `omp gc` in every omp agent directory the sessions
/// use, Lantern's own data under `$APP_SUPPORT` and its unreferenced terminal snapshots, and the free space. One
/// operation runs at a time: `omp gc` locks its agent directory, and a clean-up must not race a report over the same
/// files.
actor StorageMaintenance {
    private let paths: AppSupportPaths
    private let manifest: ManifestPublisher
    private let ptys: PTYPool
    /// The daemon's environment and configured omp, for the omp a new session gets.
    private let baseEnvironment: [String: String]
    private let ompExecutable: String?
    /// The operation queued last; the next one starts after it.
    private var tail: Task<Void, Never>?

    init(
        paths: AppSupportPaths, manifest: ManifestPublisher, ptys: PTYPool, baseEnvironment: [String: String],
        ompExecutable: String?
    ) {
        self.paths = paths
        self.manifest = manifest
        self.ptys = ptys
        self.baseEnvironment = baseEnvironment
        self.ompExecutable = ompExecutable
    }

    func report() async -> StorageReport {
        await serialized { await self.makeReport() }
    }

    func clean() async -> StorageClean.Result {
        await serialized { await self.performClean() }
    }

    private func serialized<T: Sendable>(_ body: @escaping @Sendable () async -> T) async -> T {
        let previous = tail
        let task = Task {
            await previous?.value
            return await body()
        }
        tail = Task { _ = await task.value }
        return await task.value
    }

    private func makeReport() async -> StorageReport {
        let entries = await manifest.sessions
        let (omp, failures) = await collect(entries: entries, apply: false)
        let snapshots = await ptys.unreferencedSnapshots(sessions: Set(entries.map(\.sessionKey)))
        let space = StorageWatch.space(at: paths.root)
        return StorageReport(
            omp: omp,
            ide: IDEStorage(
                totalBytes: Self.allocatedSize(of: paths.root), unreferencedSnapshots: snapshots.count,
                unreferencedSnapshotBytes: snapshots.bytes),
            freeBytes: space?.free ?? 0, volumeBytes: space?.total ?? 0, failures: failures)
    }

    private func performClean() async -> StorageClean.Result {
        let entries = await manifest.sessions
        let (omp, failures) = await collect(entries: entries, apply: true)
        let removed = await ptys.removeUnreferencedSnapshots(sessions: Set(entries.map(\.sessionKey)))
        return StorageClean.Result(omp: omp, removedSnapshots: removed.count, removedSnapshotBytes: removed.bytes, failures: failures)
    }

    /// `omp gc` for every target at once; one result per agent directory (two environments can name the same one).
    private func collect(entries: [SessionManifestEntry], apply: Bool) async -> (omp: [OmpStorage], failures: [String]) {
        var failures: [String] = []
        let located = Result { try OmpBinary.locate(explicit: ompExecutable, environment: baseEnvironment) }
        let targets = OmpGarbageCollector.targets(entries: entries, baseEnvironment: baseEnvironment, located: try? located.get())
        if targets.isEmpty, case .failure(let error) = located { failures.append("omp gc: \(error)") }
        let outcomes = await withTaskGroup(of: (Int, Result<OmpStorage, any Error>).self) { group in
            for (index, target) in targets.enumerated() {
                group.addTask {
                    do {
                        return (index, .success(try await OmpGarbageCollector.run(target, apply: apply)))
                    } catch {
                        return (index, .failure(error))
                    }
                }
            }
            var outcomes: [(Int, Result<OmpStorage, any Error>)] = []
            for await outcome in group { outcomes.append(outcome) }
            return outcomes.sorted { $0.0 < $1.0 }.map(\.1)
        }
        var results: [OmpStorage] = []
        for (target, outcome) in zip(targets, outcomes) {
            switch outcome {
            case .success(let storage):
                if !results.contains(where: { $0.agentDir == storage.agentDir }) { results.append(storage) }
            case .failure(let error):
                failures.append("omp gc with \(target.omp): \(error)")
            }
        }
        return (results, failures)
    }

    /// Bytes on disk of the regular files under `directory`.
    static func allocatedSize(of directory: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: Array(keys)) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in walker {
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}

/// `omp gc` through omp's CLI: a report is `omp gc --json` (a dry run), a clean-up `omp gc --json --apply
/// --blobs --wal`. Never `--archive`: it moves cold session files out of the session folders, and ompd or Open Session…
/// may still resume them.
enum OmpGarbageCollector {
    /// One run: an omp, and the environment that picks its agent directory.
    struct Target: Sendable, Equatable {
        var omp: String
        var environment: [String: String]
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    /// A sweep of a large agent directory takes a while; this bounds a hung one.
    static let timeout: Duration = .seconds(120)

    static func arguments(apply: Bool) -> [String] {
        apply ? ["gc", "--json", "--apply", "--blobs", "--wal"] : ["gc", "--json"]
    }

    /// One target per agent-directory environment (`Daemon.pinnedEnvironmentKeys` merged over `baseEnvironment`) of the
    /// sessions, running ones first, and of a new session: the pinned omp of a session there whose omp is still on disk,
    /// else `located` (the omp a new session gets; an environment without either is skipped).
    static func targets(entries: [SessionManifestEntry], baseEnvironment: [String: String], located: String?) -> [Target] {
        let running: Set<SessionStatus> = [.starting, .resuming, .idle, .busy, .paused]
        let candidates = entries.filter { running.contains($0.status) } + entries.filter { !running.contains($0.status) }
        var targets: [Target] = []
        var covered: [[String?]] = []
        func add(_ environment: [String: String], omp: String?) {
            let key = Daemon.pinnedEnvironmentKeys.map { environment[$0] }
            guard let omp, !covered.contains(key) else { return }
            covered.append(key)
            targets.append(Target(omp: omp, environment: environment))
        }
        for entry in candidates where OmpBinary.isUsable(entry.launch.ompPath) {
            add(baseEnvironment.merging(entry.launch.env) { $1 }, omp: entry.launch.ompPath)
        }
        for entry in candidates {
            add(baseEnvironment.merging(entry.launch.env) { $1 }, omp: located)
        }
        add(baseEnvironment, omp: located)
        return targets
    }

    static func run(_ target: Target, apply: Bool) async throws -> OmpStorage {
        let (reason, status, output) = try await OmpBinary.run(
            target.omp, arguments: arguments(apply: apply), environment: target.environment, timeout: timeout)
        guard reason == .exit, status == 0 else {
            throw Failure(description: "omp gc ended with \(reason == .exit ? "exit code" : "signal") \(status)")
        }
        return try parse(output)
    }

    /// What `omp gc --json` printed: `{agentDir, apply, blobs: {wouldDelete, deleted, bytes, errors}, archive:
    /// {wouldArchive, errors}, wal: {walBytes, checkpointed}}`, with only the sections that ran (`--blobs --wal` leaves
    /// out `archive`). Blobs count what was deleted when `apply`, else what would be.
    static func parse(_ output: String) throws -> OmpStorage {
        guard let start = output.firstIndex(of: "{"), let end = output.lastIndex(of: "}"), start < end,
              let json = try? JSONDecoder().decode(JSONValue.self, from: Data(output[start...end].utf8)),
              let agentDir = json["agentDir"]?.stringValue
        else { throw Failure(description: "omp gc printed no report: \(output.prefix(200))") }
        let applied = json["apply"]?.boolValue == true
        let (blobs, wal, archive) = (json["blobs"], json["wal"], json["archive"])
        func bytes(_ value: JSONValue?) -> Int64 { value?.doubleValue.map { Int64($0) } ?? 0 }
        return OmpStorage(
            agentDir: agentDir, blobs: blobs?[applied ? "deleted" : "wouldDelete"]?.intValue ?? 0,
            blobBytes: bytes(blobs?["bytes"]), walBytes: bytes(wal?["walBytes"]),
            walCheckpointed: wal?["checkpointed"]?.boolValue == true, archiveCandidates: archive?["wouldArchive"]?.intValue,
            errors: [blobs, archive, wal].flatMap { $0?["errors"]?.arrayValue ?? [] }.map(describe))
    }

    /// One entry of an `errors` list: its text, or its `message`, else its JSON.
    private static func describe(_ error: JSONValue) -> String {
        if let text = error.stringValue ?? error["message"]?.stringValue ?? error["error"]?.stringValue { return text }
        return (try? JSONEncoder().encode(error)).map { String(decoding: $0, as: UTF8.self) } ?? "?"
    }
}
