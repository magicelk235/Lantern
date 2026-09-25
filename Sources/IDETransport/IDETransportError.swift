import Foundation

/// Transport-level failures. Protocol-level refusals from the daemon (bad token, version skew, handler errors) are
/// thrown as `DaemonError` instead.
public enum IDETransportError: Error, Sendable, Equatable {
    /// The path does not fit `sockaddr_un.sun_path` (at most 103 bytes).
    case socketPathTooLong(path: String)
    /// Something other than a socket exists at the socket path; it is never deleted.
    case socketPathOccupied(path: String)
    /// A live listener already owns the socket path (another daemon is running).
    case addressInUse(path: String)
    /// A POSIX call on the socket path failed.
    case systemCall(String, errno: Int32)
    /// The `NWListener` could not be started.
    case listenerFailed(String)
    /// `IDEServer.start()` called twice or after `stop()`.
    case invalidState(String)
    /// The client could not reach the daemon socket (missing, refused, ...).
    case connectFailed(String)
    /// The connection closed before the operation completed.
    case connectionClosed
    /// The peer sent bytes that violate the frame protocol.
    case protocolViolation(String)
    /// `IDEClient.call` before a successful `connect()` or after `close()`.
    case notConnected
}
