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

    /// Waits for the bridge of `sessionKey`, whose connection ended while its omp runs, to say hello again with the
    /// same credentials (an ompd upgrade, a dropped connection); the current connection's hello while one is up. Fails
    /// once the key is forgotten.
    func waitForRedial(_ sessionKey: SessionKey) async throws -> BridgeHello

    /// One bridge method call (`session.ensureOnDisk`, `agents.snapshot`, …); returns its result.
    func call(_ sessionKey: SessionKey, method: String, params: JSONValue, timeout: Duration) async throws -> JSONValue

    /// Bridge pushes (`evt` and `gap` frames, verbatim) of the current connection of `sessionKey`'s bridge. Single
    /// consumer; finishes when that connection ends.
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

    /// An in-place upgrade: stops accepting and ends every bridge connection without losing an event; true
    /// when all ended within `timeout`. The credentials stay for the redials.
    func quiesce(timeout: Duration) async -> Bool

    /// The credentials of every session and terminal, for the next image.
    func handoverState() async -> BridgeHandover

    /// After `quiesce`, when the handover did not happen: accepts the redials again.
    func resumeListening() async throws
}

extension BridgeServer: SessionBridgeLink {}

/// Session-ownership locks: ompd holds an exclusive lock per owned session file for as long as it owns
/// the session, so no second omp (and no second daemon) can open it.
public protocol SessionLockProvider: Sendable {
    /// Takes the lock of `sessionFile` (which may not exist yet). Throws `DaemonError(.sessionBusy)` when someone else
    /// holds it; any other error means the lock could not be taken for another reason.
    func acquire(sessionFile: String, sessionId: String?, sessionKey: SessionKey) throws -> any SessionLockHandle

    /// The lock of `sessionFile` the previous image of this process held on `descriptor` and kept open across an
    /// in-place upgrade: held from now on, close-on-exec again.
    func adopt(descriptor: Int32, sessionFile: String) throws -> any SessionLockHandle
}

/// A held session-ownership lock. The kernel drops it when the daemon dies.
public protocol SessionLockHandle: Sendable {
    func release()
    /// The open descriptor that holds the lock, kept open across an in-place upgrade; nil once released.
    var descriptor: Int32? { get }
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

    public func adopt(descriptor: Int32, sessionFile: String) throws -> any SessionLockHandle {
        try OwnedSessionLock.adopt(descriptor: descriptor, sessionFile: sessionFile, dir: directory)
    }
}
