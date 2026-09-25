import Foundation
import IDEProtocol
import IDETransport

extension Error {
    /// The connection is gone (or was never there); the next connection retries.
    var isDisconnect: Bool {
        switch self {
        case is CancellationError: true
        case let error as IDETransportError:
            switch error {
            case .notConnected, .connectionClosed, .connectFailed: true
            default: false
            }
        default: false
        }
    }

    /// One sentence for the UI: the daemon's own message, or what went wrong with the connection.
    public var userMessage: String {
        switch self {
        case let error as DaemonError: error.message
        case let error as IDETransportError:
            switch error {
            case .notConnected: "Not connected to ompd."
            case .connectionClosed: "The connection to ompd closed."
            case .connectFailed(let reason): "ompd is not reachable (\(reason))."
            case .protocolViolation(let reason): "ompd sent something unexpected: \(reason)"
            case .socketPathTooLong(let path): "The ompd socket path is too long: \(path)"
            default: String(describing: error)
            }
        default: localizedDescription
        }
    }
}
