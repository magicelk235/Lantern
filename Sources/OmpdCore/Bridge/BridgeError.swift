import Foundation

/// Failure of the ide-bridge control channel, the session ownership lock, or bridge installation.
public enum BridgeError: Error, Sendable, Equatable, CustomStringConvertible {
    /// No live bridge connection: the session was never `expect`ed, was forgotten, or its `hello` was not accepted yet.
    case notConnected
    /// No valid `hello` arrived within the wait's timeout.
    case helloTimeout
    /// The wait timed out after at least one `hello` for the session was rejected (bad token, wrong peer pid, ...).
    case unauthorized
    /// The accepted bridge connection ended (omp exited or closed it, `forget`, `expect` again, `stop`).
    case disconnected
    /// The bridge answered `ok: false`.
    case callFailed(method: String, message: String)
    /// The bridge did not answer within the call's timeout.
    case callTimeout(method: String)
    /// `OwnedSessionLock.acquire`: another open file description holds the session's ownership lock.
    case alreadyOwned(sessionFile: String)
    /// `BridgeInstaller.locateSource`: no ide-bridge.ts at any candidate path.
    case sourceNotFound(searched: [String])
    /// The socket path does not fit `sockaddr_un.sun_path` (103 bytes plus NUL).
    case socketPathTooLong(path: String)
    /// Another process is listening on the socket path.
    case addressInUse(path: String)
    /// Something other than a socket occupies the socket path.
    case socketPathOccupied(path: String)
    /// API misuse, e.g. `start()` twice.
    case invalidState(String)
    /// A system call failed with `errno` `code`.
    case system(operation: String, path: String, code: Int32)

    public var description: String {
        switch self {
        case .notConnected: "no bridge connection for this session"
        case .helloTimeout: "the ide-bridge did not say hello in time"
        case .unauthorized: "every ide-bridge hello for this session was rejected"
        case .disconnected: "the ide-bridge connection ended"
        case .callFailed(let method, let message): "bridge \(method) failed: \(message)"
        case .callTimeout(let method): "bridge \(method) timed out"
        case .alreadyOwned(let sessionFile): "\(sessionFile) is already owned"
        case .sourceNotFound(let searched): "ide-bridge.ts not found (searched \(searched.joined(separator: ", ")))"
        case .socketPathTooLong(let path): "socket path too long: \(path)"
        case .addressInUse(let path): "another process listens on \(path)"
        case .socketPathOccupied(let path): "\(path) exists and is not a socket"
        case .invalidState(let message): message
        case .system(let operation, let path, let code): "\(operation)(\(path)) failed: \(String(cString: strerror(code)))"
        }
    }
}
