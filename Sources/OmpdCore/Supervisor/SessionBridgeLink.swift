import Foundation
import IDEProtocol

/// The part of the ide-bridge control plane a `SessionSupervisor` and the daemon use:
/// per-spawn credentials, the `hello` handshake, request/response calls and the event push stream of one omp process,
/// and the adoption of omps the user starts in the IDE's terminals. `BridgeServer` is the production implementation;
/// tests substitute a scripted bridge.
public protocol SessionBridgeLink: Sendable {
    /// Registers the spawn that is about to happen; the credentials' environment goes into the omp child's.
    func expect(sessionKey: SessionKey) async -> BridgeCredentials

    /// The omp child of `sessionKey` was spawned as `pid`; only that process may complete the handshake.
    func setExpectedPID(_ pid: Int32, for sessionKey: SessionKey) async

    /// Waits for the bridge inside the omp child to connect and say `hello`.
    func waitForHello(_ sessionKey: SessionKey, timeout: Duration) async throws -> BridgeHello

    /// One bridge method call (`session.ensureOnDisk`, `agents.snapshot`, …); returns its result.
    func call(_ sessionKey: SessionKey, method: String, params: JSONValue, timeout: Duration) async throws -> JSONValue

    /// Bridge pushes (`evt` and `gap` frames, verbatim) of the current spawn of `sessionKey`. Single consumer;
    /// finishes when the bridge disconnects.
    func events(_ sessionKey: SessionKey) async -> AsyncStream<JSONValue>

    /// Drops everything the bridge holds for `sessionKey` (its omp exited).
    func forget(_ sessionKey: SessionKey) async

    /// Credentials for the program of terminal PTY `ptyId` (its environment), so an omp the user starts there can say
    /// hello in terminal mode; good until `forgetTerminal`.
    func expectTerminal(ptyId: PTYID) async -> TerminalCredentials

    /// The terminal PTY is gone; its credentials are void.
    func forgetTerminal(ptyId: PTYID) async

    /// Authenticated terminal-mode hellos awaiting the daemon's verdict. Single consumer.
    func terminalHellos() async -> AsyncStream<TerminalHello>

    /// Adopts the omp of `hello` as the bridge of `sessionKey`: `welcome`, then `waitForHello`, `call`, `events` and
    /// `forget` serve it by that key. Nil when the omp went away before the verdict.
    func adoptTerminalHello(_ hello: TerminalHello, as sessionKey: SessionKey) async -> BridgeHello?

    /// Rejects the omp of `hello`.
    func refuseTerminalHello(_ hello: TerminalHello, reason: String) async
}

extension BridgeServer: SessionBridgeLink {}

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

extension OwnedSessionLock: SessionLockHandle {}

/// `OwnedSessionLock`s in `$APP_SUPPORT/run/owned-sessions`, the directory the lock-mode ide-bridge probes.
public struct OwnedSessionLocks: SessionLockProvider {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public func acquire(sessionFile: String, sessionId: String?, sessionKey: SessionKey) throws -> any SessionLockHandle {
        do {
            return try OwnedSessionLock.acquire(sessionFile: sessionFile, sessionId: sessionId, sessionKey: sessionKey, dir: directory)
        } catch BridgeError.alreadyOwned(let file) {
            throw DaemonError(.sessionBusy, "\(file) is owned by another omp process")
        }
    }
}
