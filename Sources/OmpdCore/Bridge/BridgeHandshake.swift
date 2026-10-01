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

/// What ompd puts into the environment of every terminal PTY's program (`pty.open`, and terminals restored after a
/// daemon restart) so an omp the user starts from that shell can dial back and be adopted as a session: the bridge
/// socket, the terminal's PTY id, a token per terminal and the daemon's pid. No session key: the bridge's terminal
/// mode says hello with `ptyId` and this token instead, and checks the daemon pid is alive rather than its parent
/// (the omp is the shell's child, not ompd's). The token serves every omp started in that terminal, one at a time,
/// until the PTY is closed; never persisted (a restored terminal gets fresh credentials).
public struct TerminalCredentials: Sendable, Equatable {
    public static let ptyVariable = "OMP_IDE_TERMINAL_PTY"
    public static let tokenVariable = "OMP_IDE_TERMINAL_TOKEN"

    public let socketPath: String
    public let ptyId: PTYID
    /// 64 hex characters.
    public let token: String
    public let daemonPID: Int32

    /// The `OMP_IDE_*` variables to merge into the terminal program's environment.
    public var environment: [String: String] {
        [
            BridgeCredentials.socketVariable: socketPath, Self.ptyVariable: ptyId, Self.tokenVariable: token,
            BridgeCredentials.daemonPIDVariable: String(daemonPID),
        ]
    }
}

/// An accepted ide-bridge handshake: token and peer pid verified by `BridgeServer`.
public struct BridgeHello: Sendable, Equatable {
    /// The session the omp serves: the key ompd spawned it for, or — for an omp started in a terminal (`ptyId`) — the
    /// key ompd adopted it into (`adoptTerminalHello`); empty while such a hello awaits ompd's verdict.
    public internal(set) var sessionKey: SessionKey
    /// The terminal PTY an omp the user started said hello from (`TerminalCredentials`); nil for an omp ompd spawned.
    public let ptyId: PTYID?
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
    /// Who holds omp's pause gate closed when the bridge said hello; nil while it is open (and from older bridges).
    public let pausedBy: PauseOwner?
    /// What waited for the user in omp's TUI when the bridge said hello (tool approvals, `ask`), oldest first; empty from
    /// bridges without `events.attention`.
    public let attention: [AttentionItem]
    /// The hello frame without `token`.
    public let raw: JSONValue
}

extension BridgeHello {
    struct Malformed: Error, CustomStringConvertible {
        let description: String
    }

    /// Parses a `hello` frame received from the socket peer `peerPID`; the frame's own `pid` must match it. `sessionKey`
    /// is the frame's for a spawned omp's hello; a terminal-mode hello (`ptyId` instead) gets the empty key until ompd
    /// adopts it.
    init(frame: [String: JSONValue], sessionKey: SessionKey, peerPID: pid_t) throws(Malformed) {
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
        let pausedBy = PauseOwner(paused: session["paused"]?.boolValue == true, by: session["pausedBy"]?.stringValue)
        self.init(
            sessionKey: sessionKey, ptyId: frame["ptyId"]?.stringValue, pid: pid, ompVersion: ompVersion,
            capabilities: capabilities.compactMapValues(\.boolValue), sessionId: sessionId, sessionFile: sessionFile,
            onDisk: onDisk, cwd: cwd, artifactsDir: session["artifactsDir"]?.stringValue,
            title: session["title"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 },
            pausedBy: pausedBy, attention: RuntimeTracker.attention(session["attention"]),
            raw: .object(raw))
    }
}

/// A `hello` from an omp the user started in one of the IDE's terminals (the ide-bridge's terminal mode), whose
/// terminal token and peer pid `BridgeServer` verified, waiting for ompd's verdict: `adoptTerminalHello` makes it a
/// session's bridge, `refuseTerminalHello` turns it away (the bridge then behaves as in lock mode).
public struct TerminalHello: Sendable {
    /// The terminal PTY the omp runs in.
    public let ptyId: PTYID
    /// The handshake; its `sessionKey` is empty until ompd adopts it.
    public let hello: BridgeHello
    /// The server's connection, for the verdict.
    let peerID: Int
}
