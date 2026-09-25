import Darwin
import Foundation
import IDEProtocol

/// What ompd adds to the environment of an omp it spawns so the ide-bridge inside can dial back.
/// Never persisted: the token is fresh per spawn and worthless once that omp is gone. The omp must be a
/// direct child of the daemon process (no forking wrapper): processes that omp spawns inherit these variables, and the
/// bridge tells them apart by `getppid() == OMP_IDE_DAEMON_PID`.
public struct BridgeCredentials: Sendable, Equatable {
    public static let socketVariable = "OMP_IDE_BRIDGE_SOCK"
    public static let sessionKeyVariable = "OMP_IDE_SESSION_KEY"
    public static let tokenVariable = "OMP_IDE_BRIDGE_TOKEN"
    public static let daemonPIDVariable = "OMP_IDE_DAEMON_PID"

    public let socketPath: String
    public let sessionKey: SessionKey
    /// 64 hex characters, accepted for exactly one `hello`.
    public let token: String
    /// The process that spawns omp (ompd).
    public let daemonPID: Int32

    /// The `OMP_IDE_*` variables to merge into the omp child's environment.
    public var environment: [String: String] {
        [
            Self.socketVariable: socketPath, Self.sessionKeyVariable: sessionKey, Self.tokenVariable: token,
            Self.daemonPIDVariable: String(daemonPID),
        ]
    }
}

/// An accepted ide-bridge handshake: token and peer pid verified by `BridgeServer`.
public struct BridgeHello: Sendable, Equatable {
    public let sessionKey: SessionKey
    /// omp's pid, verified with `LOCAL_PEERPID`.
    public let pid: Int32
    public let ompVersion: String
    /// Bridge method or event feature → usable in this omp build, e.g. `"agent.revive": false` when the internal module
    /// behind it is missing. Disable the feature instead of calling it.
    public let capabilities: [String: Bool]
    public let sessionId: String
    public let sessionFile: String
    /// Whether omp already crossed its lazy file-creation gate (`session.ensureOnDisk`).
    public let onDisk: Bool
    public let cwd: String
    public let artifactsDir: String?
    /// The session's name when the bridge said hello (a resumed session keeps its title); nil when unnamed.
    public let title: String?
    /// The hello frame without `token`.
    public let raw: JSONValue
}

extension BridgeHello {
    struct Malformed: Error, CustomStringConvertible {
        let description: String
    }

    /// Parses a `hello` frame received from the socket peer `peerPID`; the frame's own `pid` must match it.
    init(frame: [String: JSONValue], peerPID: pid_t) throws(Malformed) {
        guard let sessionKey = frame["sessionKey"]?.stringValue else { throw Malformed(description: "sessionKey missing") }
        guard let number = frame["pid"]?.doubleValue, let pid = Int32(exactly: number) else {
            throw Malformed(description: "pid missing")
        }
        guard pid == peerPID else {
            throw Malformed(description: "hello pid \(pid) is not the socket peer's pid \(peerPID)")
        }
        guard let ompVersion = frame["ompVersion"]?.stringValue else { throw Malformed(description: "ompVersion missing") }
        guard case .object(let capabilities)? = frame["capabilities"] else {
            throw Malformed(description: "capabilities missing")
        }
        guard case .object(let session)? = frame["session"],
            let sessionId = session["id"]?.stringValue,
            let sessionFile = session["file"]?.stringValue,
            let onDisk = session["onDisk"]?.boolValue,
            let cwd = session["cwd"]?.stringValue
        else { throw Malformed(description: "session {id, file, onDisk, cwd} missing") }
        var raw = frame
        raw["token"] = nil
        self.init(
            sessionKey: sessionKey, pid: pid, ompVersion: ompVersion,
            capabilities: capabilities.compactMapValues(\.boolValue), sessionId: sessionId, sessionFile: sessionFile,
            onDisk: onDisk, cwd: cwd, artifactsDir: session["artifactsDir"]?.stringValue,
            title: session["title"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }, raw: .object(raw))
    }
}
