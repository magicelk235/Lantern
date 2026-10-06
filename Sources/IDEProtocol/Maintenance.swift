import Foundation

// Hardening: a session restarted onto the omp installed now, and what omp and
// Lantern can reclaim on disk. Additive to protocol 5: an ompd from before these methods answers `unknown_method`.

// MARK: - omp upgrades

/// Precedence of omp versions as semantic versioning orders them: `18.4.4` < `18.4.8` < `18.5.0-beta.1` < `18.5.0`.
/// Build metadata (`+…`) does not count.
public enum OmpVersion {
    /// `version` sorts before `other`; false when either is not `major.minor.patch[-prerelease][+build]`.
    public static func isOlder(_ version: String, than other: String) -> Bool {
        guard let version = Parsed(version), let other = Parsed(other) else { return false }
        return version < other
    }

    private struct Parsed: Comparable {
        var core: [Int]
        var prerelease: [Substring]

        init?(_ text: String) {
            let release = text.prefix { $0 != "+" }
            let core = release.prefix { $0 != "-" }
            let numbers = core.split(separator: ".", omittingEmptySubsequences: false).map { part in
                part.allSatisfy(\.isASCII) && part.allSatisfy(\.isNumber) ? Int(part) : nil
            }
            guard numbers.count == 3, numbers.allSatisfy({ $0 != nil }) else { return nil }
            self.core = numbers.compactMap { $0 }
            prerelease = core.endIndex == release.endIndex
                ? [] : release[release.index(after: core.endIndex)...].split(separator: ".", omittingEmptySubsequences: false)
            guard !prerelease.contains(where: \.isEmpty) else { return nil }
        }

        static func < (a: Parsed, b: Parsed) -> Bool {
            if a.core != b.core { return a.core.lexicographicallyPrecedes(b.core) }
            // A pre-release precedes its release.
            if a.prerelease.isEmpty || b.prerelease.isEmpty { return !a.prerelease.isEmpty && b.prerelease.isEmpty }
            for (x, y) in zip(a.prerelease, b.prerelease) where x != y {
                switch (Int(x), Int(y)) {
                case let (x?, y?): return x < y
                case (.some, nil): return true // numeric identifiers precede alphanumeric ones
                case (nil, .some): return false
                case (nil, nil): return x < y
                }
            }
            return a.prerelease.count < b.prerelease.count
        }
    }
}

extension SessionManifestEntry {
    /// The version of the omp installed at `launch.ompPath` when it is newer than the one this session's omp runs
    /// (`launch.ompVersion`, read at its spawn): what `SessionRestart` would bring. nil while omp does not run, for an
    /// omp the user started in a terminal (`adopted`), and until ompd read the installed version.
    public var ompUpgrade: String? {
        guard !adopted, [.idle, .busy, .paused].contains(status), let installed = installedOmpVersion,
              OmpVersion.isOlder(launch.ompVersion, than: installed)
        else { return nil }
        return installed
    }
}

/// Restart Session: omp stops the graceful way (bridge `session.shutdown`) and is resumed
/// at once with `--resume` in a new PTY that continues its screen, running the omp installed at `launch.ompPath` now.
/// What the stop interrupts is continued whatever the restore policy (`auto`, for this restart only); an interruption
/// already waiting for a decision keeps waiting. Refused with `sessionBusy` while the main agent is busy (unless
/// `force`) or while omp is not running, `badParams` for an omp the user started in a terminal, `readOnly` while ompd
/// cannot write its manifest. Result: the entry once the new omp runs.
public enum SessionRestart: DaemonMethod {
    public static let name = "session.restart"
    public struct Params: Codable, Sendable, Equatable {
        public var sessionKey: SessionKey
        /// Restart even while the main agent is busy: its turn is interrupted, then continued.
        public var force: Bool

        public init(sessionKey: SessionKey, force: Bool = false) {
            self.sessionKey = sessionKey
            self.force = force
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            sessionKey = try container.decode(SessionKey.self, forKey: .sessionKey)
            force = try container.decodeIfPresent(Bool.self, forKey: .force) ?? false
        }
    }
    public typealias Result = SessionManifestEntry
}

// MARK: - Storage

extension DaemonNotice {
    /// `topic` of a notice about low free space, or about a write that failed for want of it: clients offer to free up
    /// space.
    public static let diskSpaceTopic = "disk_space"
}

/// What `omp gc --json` says about one omp agent directory (`~/.omp/agent`, or a profile's): unreferenced blobs and the
/// write-ahead logs of omp's databases. ompd never runs `omp gc --archive`: it moves cold session files out of the
/// session folders, and ompd or Open Session… may still resume them.
public struct OmpStorage: Codable, Sendable, Equatable {
    public var agentDir: String
    /// Unreferenced blobs omp would delete (a report) or deleted (a clean-up), and their bytes.
    public var blobs: Int
    public var blobBytes: Int64
    /// Bytes in the write-ahead logs of omp's databases (`history.db`, `models.db`), which a checkpoint folds back. In
    /// a clean-up, what is left after the checkpoint (omp measures again; 0 when it succeeded).
    public var walBytes: Int64
    /// The clean-up checkpointed the write-ahead logs; false in a report.
    public var walCheckpointed: Bool
    /// Cold sessions `omp gc --archive` would move; nil when omp did not say (a clean-up). Information only.
    public var archiveCandidates: Int?
    /// What omp could not do, as it said it.
    public var errors: [String]

    public init(
        agentDir: String, blobs: Int, blobBytes: Int64, walBytes: Int64, walCheckpointed: Bool = false,
        archiveCandidates: Int? = nil, errors: [String] = []
    ) {
        self.agentDir = agentDir
        self.blobs = blobs
        self.blobBytes = blobBytes
        self.walBytes = walBytes
        self.walCheckpointed = walCheckpointed
        self.archiveCandidates = archiveCandidates
        self.errors = errors
    }
}

/// Lantern's own data under `$APP_SUPPORT`, as ompd sees it.
public struct IDEStorage: Codable, Sendable, Equatable {
    /// Everything under `$APP_SUPPORT`: the manifest, terminal snapshots, `state.sqlite`, hot-exit copies.
    public var totalBytes: Int64
    /// Files in `pty/` no terminal or session refers to: snapshots of terminals and sessions that are gone, and what an
    /// interrupted snapshot write left.
    public var unreferencedSnapshots: Int
    public var unreferencedSnapshotBytes: Int64

    public init(totalBytes: Int64, unreferencedSnapshots: Int, unreferencedSnapshotBytes: Int64) {
        self.totalBytes = totalBytes
        self.unreferencedSnapshots = unreferencedSnapshots
        self.unreferencedSnapshotBytes = unreferencedSnapshotBytes
    }
}

/// What omp and Lantern could reclaim, and the free space left.
public struct StorageReport: Codable, Sendable, Equatable {
    /// One per omp agent directory: those the sessions use and the one a new session gets, as `omp gc --json` (a dry run)
    /// reports them.
    public var omp: [OmpStorage]
    public var ide: IDEStorage
    /// Free and total bytes of the volume `$APP_SUPPORT` is on (`statfs`).
    public var freeBytes: Int64
    public var volumeBytes: Int64
    /// The agent directories `omp gc` failed for, one line each.
    public var failures: [String]

    public init(omp: [OmpStorage], ide: IDEStorage, freeBytes: Int64, volumeBytes: Int64, failures: [String] = []) {
        self.omp = omp
        self.ide = ide
        self.freeBytes = freeBytes
        self.volumeBytes = volumeBytes
        self.failures = failures
    }
}

/// `storage.report`: `omp gc --json` (a dry run) in every agent directory the sessions use, through a session's pinned
/// omp and environment (else the omp a new session gets), plus Lantern's own data and the free space.
public enum StorageReportRequest: DaemonMethod {
    public static let name = "storage.report"
    public typealias Params = Empty
    public typealias Result = StorageReport
}

/// `storage.clean`: `omp gc --json --apply --blobs --wal` in every agent directory `storage.report` covers (never
/// `--archive`), and the unreferenced terminal snapshots removed. Result: what was reclaimed.
public enum StorageClean: DaemonMethod {
    public static let name = "storage.clean"
    public typealias Params = Empty
    public struct Result: Codable, Sendable, Equatable {
        /// What `omp gc --apply` did, per agent directory: blobs deleted, write-ahead logs checkpointed.
        public var omp: [OmpStorage]
        public var removedSnapshots: Int
        public var removedSnapshotBytes: Int64
        /// The agent directories `omp gc` failed for, one line each.
        public var failures: [String]

        public init(omp: [OmpStorage], removedSnapshots: Int, removedSnapshotBytes: Int64, failures: [String] = []) {
            self.omp = omp
            self.removedSnapshots = removedSnapshots
            self.removedSnapshotBytes = removedSnapshotBytes
            self.failures = failures
        }
    }
}
