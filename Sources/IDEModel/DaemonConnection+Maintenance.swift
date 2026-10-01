import Foundation
import IDEProtocol

// Hardening: restarting a session on the omp installed now, and what omp and omp IDE can reclaim on disk.
// An ompd older than these methods answers `unknown_method`; the error then says to restart ompd.
extension DaemonConnection {
    /// Stops the session's omp gracefully and resumes it on the omp installed now (`session.restart`); its tab follows
    /// omp to the new PTY. `force` restarts even while the agent works (its turn is interrupted, then continued).
    @discardableResult
    public func restartSession(_ sessionKey: SessionKey, force: Bool = false) async throws -> SessionManifestEntry {
        try await callNewer(SessionRestart.self, .init(sessionKey: sessionKey, force: force), doing: "restart sessions")
    }

    /// What `omp gc` and omp IDE could reclaim, and the free disk space (`storage.report`; runs `omp gc --json`, a dry
    /// run, in every agent directory the sessions use).
    public func storageReport() async throws -> StorageReport {
        try await callNewer(StorageReportRequest.self, Empty(), doing: "report storage")
    }

    /// `omp gc --apply --blobs --wal` in those agent directories (never `--archive`) and ompd's unreferenced terminal
    /// screens removed (`storage.clean`).
    public func cleanStorage() async throws -> StorageClean.Result {
        try await callNewer(StorageClean.self, Empty(), doing: "clean up storage")
    }

    /// `method`, with the `unknown_method` of an ompd from before it turned into a message that says what to do.
    private func callNewer<M: DaemonMethod>(_ method: M.Type, _ params: M.Params, doing what: String) async throws -> M.Result {
        do {
            return try await connectedClient().call(method, params)
        } catch let error as DaemonError where error.code == .unknownMethod {
            throw DaemonError(.unknownMethod, "The running ompd is older than omp IDE and cannot \(what). Restart ompd to update it.")
        }
    }
}
