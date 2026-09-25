import Foundation
import IDEProtocol

/// The ide-bridge control plane as a `SessionSupervisor` uses it: per-spawn
/// credentials, the `hello` handshake, request/response calls and the event push stream of one omp process.
/// `BridgeServer` is the production implementation; tests substitute a scripted bridge.
public protocol SessionBridgeLink: Sendable {
    /// Registers the spawn that is about to happen and returns the environment variables the omp child needs to
    /// reach the bridge socket (`OMP_IDE_BRIDGE_SOCK`, `OMP_IDE_SESSION_KEY`, a fresh `OMP_IDE_BRIDGE_TOKEN`).
    /// They are never persisted.
    func prepareSpawn(of sessionKey: SessionKey) async -> [String: String]

    /// The omp child of `sessionKey` was spawned as `pid`; only that process may complete the handshake.
    func spawned(_ sessionKey: SessionKey, pid: Int32) async

    /// Waits for the bridge inside the omp child to connect and say `hello`.
    func hello(_ sessionKey: SessionKey, timeout: Duration) async throws -> BridgeSessionInfo

    /// One bridge method call (`session.ensureOnDisk`, `agents.snapshot`, …); returns its result.
    func call(_ sessionKey: SessionKey, method: String, params: JSONValue, timeout: Duration) async throws -> JSONValue

    /// Bridge pushes (`evt` and `gap` frames, verbatim) for the current connection of `sessionKey`. Single consumer;
    /// finishes when the bridge disconnects.
    func events(_ sessionKey: SessionKey) async -> AsyncStream<JSONValue>

    /// Drops everything the bridge holds for `sessionKey` (its omp exited).
    func forget(_ sessionKey: SessionKey) async
}

/// What the bridge reports in its `hello`: the session omp opened, known before the session file exists.
public struct BridgeSessionInfo: Sendable, Equatable {
    public var pid: Int32
    public var ompVersion: String
    public var capabilities: [String: Bool]
    public var sessionId: String
    public var sessionFile: String
    public var onDisk: Bool
    public var raw: JSONValue

    public init(
        pid: Int32, ompVersion: String, capabilities: [String: Bool], sessionId: String, sessionFile: String, onDisk: Bool,
        raw: JSONValue
    ) {
        self.pid = pid
        self.ompVersion = ompVersion
        self.capabilities = capabilities
        self.sessionId = sessionId
        self.sessionFile = sessionFile
        self.onDisk = onDisk
        self.raw = raw
    }
}

/// Session-ownership locks: ompd holds an exclusive lock per owned session file for as long as it owns
/// the session, so no second omp (and no second daemon) can open it.
public protocol SessionLockProvider: Sendable {
    /// Takes the lock of `sessionFile` (which may not exist yet). Throws `DaemonError(.sessionBusy)` when someone else
    /// holds it; any other error means the lock could not be taken for another reason.
    func acquire(sessionFile: String, sessionId: String?, sessionKey: SessionKey) throws -> any SessionLockHandle
}

/// A held session-ownership lock. The kernel drops it when the daemon dies.
public protocol SessionLockHandle: Sendable {
    func release()
}
