import Foundation
import IDEProtocol

// Hardening: restarting a session on the omp installed now, what omp and Lantern can reclaim on disk, and renaming a
// project's folder with what omp keeps under its path.
// An ompd older than these methods answers `unknown_method`; the error then says to restart ompd.
extension DaemonConnection {
    /// Stops the session's omp gracefully and resumes it on the omp installed now (`session.restart`); its tab follows
    /// omp to the new PTY. `force` restarts even while the agent works (its turn is interrupted, then continued).
    @discardableResult
    public func restartSession(_ sessionKey: SessionKey, force: Bool = false) async throws -> SessionManifestEntry {
        try await callNewer(SessionRestart.self, .init(sessionKey: sessionKey, force: force), doing: "restart sessions")
    }

    /// What `omp gc` and Lantern could reclaim, and the free disk space (`storage.report`; runs `omp gc --json`, a dry
    /// run, in every agent directory the sessions use).
    public func storageReport() async throws -> StorageReport {
        try await callNewer(StorageReportRequest.self, Empty(), doing: "report storage")
    }

    /// `omp gc --apply --blobs --wal` in those agent directories (never `--archive`) and ompd's unreferenced terminal
    /// screens removed (`storage.clean`).
    public func cleanStorage() async throws -> StorageClean.Result {
        try await callNewer(StorageClean.self, Empty(), doing: "clean up storage")
    }

    /// Renames the project's folder `from` to `to` (`project.rename`): its sessions stop, the folder moves (unless
    /// `moveFolder` is false: it is at `to` already, moved in the Finder), omp's sessions, memory and history follow,
    /// and the sessions resume in the renamed folder once the answer is out. The error says why in the Finder's words
    /// when the folder cannot be renamed.
    public func renameProject(from: String, to: String, moveFolder: Bool = true) async throws -> ProjectRename.Result {
        try await callNewer(ProjectRename.self, .init(from: from, to: to, moveFolder: moveFolder), doing: "rename projects")
    }

    /// `method`, with the `unknown_method` of an ompd from before it turned into a message that says what to do.
    private func callNewer<M: DaemonMethod>(_ method: M.Type, _ params: M.Params, doing what: String) async throws -> M.Result {
        do {
            return try await connectedClient().call(method, params)
        } catch let error as DaemonError where error.code == .unknownMethod {
            throw DaemonError(.unknownMethod, "The running ompd is older than Lantern and cannot \(what). Restart ompd to update it.")
        }
    }
}
