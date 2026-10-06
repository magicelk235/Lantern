import Foundation

/// `daemon.upgrade`: ompd moves to the ompd executable now installed at the path it runs from (an app update or
/// a rebuild replaced it). Preferred is Regime A, an in-place handover: the running image hands every PTY, omp process,
/// ownership lock and ide-bridge credential to the installed one (`execve` in its own process, so the pid stays and every
/// omp stays its child); no omp notices, and each omp's ide-bridge redials. When that is impossible (the installed ompd
/// predates the handover or cannot be started, or an omp's ide-bridge cannot redial), ompd restarts the graceful way
/// (Regime B2) as `mode` says. The connection closes once the upgrade happens; reconnect to reach the new
/// image. An ompd from before this method answers `unknown_method`.
public enum DaemonUpgrade: DaemonMethod {
    public static let name = "daemon.upgrade"

    public enum Mode: String, Sendable, Codable, CaseIterable {
        /// Hand over; failing that, restart at once when every session is settled, else do nothing (`busy`). What ompd
        /// does by itself when a Lantern of another version connects.
        case auto
        /// Hand over; failing that, restart at the next moment every session is settled.
        case whenSettled
        /// Hand over; failing that, restart at once: running omps are stopped gracefully and resumed with `--resume`, and
        /// the restore policy decides what agents they interrupted do.
        case now
    }

    public struct Params: Codable, Sendable, Equatable {
        public var mode: Mode
        public init(mode: Mode = .auto) { self.mode = mode }
    }

    public struct Result: Codable, Sendable, Equatable {
        public enum Outcome: String, Sendable, Codable {
            /// The executable at ompd's path is the image running: nothing to do.
            case upToDate
            /// The running image hands over to the installed one in place, as soon as no session is starting or stopping.
            case handingOver
            /// ompd restarts the graceful way into the installed executable now.
            case restarting
            /// ompd restarts the graceful way once every session is settled.
            case restartWhenSettled
            /// No handover, and a session is not settled: nothing happens until `whenSettled` or `now`.
            case busy
        }

        public var outcome: Outcome
        /// The image answering (`daemon.status`'s `daemonVersion`).
        public var runningVersion: String
        /// What the installed executable reports; nil when up to date or when it could not be started.
        public var installedVersion: String?
        /// Why ompd does not hand over in place; nil when it does, or when it is up to date.
        public var handoverUnavailable: String?
        /// Sessions that are not settled: a restart interrupts them.
        public var unsettledSessions: [SessionKey]

        public init(
            outcome: Outcome, runningVersion: String, installedVersion: String? = nil, handoverUnavailable: String? = nil,
            unsettledSessions: [SessionKey] = []
        ) {
            self.outcome = outcome
            self.runningVersion = runningVersion
            self.installedVersion = installedVersion
            self.handoverUnavailable = handoverUnavailable
            self.unsettledSessions = unsettledSessions
        }
    }
}

extension SessionStatus {
    /// omp waits for input, is paused, or does not run: an ompd restart interrupts nothing it does ("settled").
    public var isSettled: Bool {
        switch self {
        case .idle, .paused, .closed, .needsAttention: true
        case .starting, .busy, .interrupted, .resuming: false
        }
    }
}
