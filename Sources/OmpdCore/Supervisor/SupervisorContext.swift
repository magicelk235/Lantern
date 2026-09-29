import Foundation
import IDEProtocol
import os

/// Timeouts and limits of a `SessionSupervisor`.
public struct SupervisorTimings: Sendable {
    /// Spawn to the bridge `hello` (the TUI loads its extensions first). On expiry the session runs without bridge
    /// features (no status, title or graceful stop).
    public var hello: Duration
    /// One bridge call (`session.shutdown`, …).
    public var bridgeCall: Duration
    /// Graceful stop (bridge `session.shutdown`, else SIGHUP) to exit (15 s of launchd's ~20 s).
    public var stop: Duration
    /// SIGHUP to exit before the process group is killed.
    public var hangup: Duration
    /// Answer to the post-wake `session.info` health check.
    public var healthCheck: Duration
    /// Crash-loop guard: at most `maxRespawns` automatic respawns within `respawnWindow`.
    public var respawnWindow: Duration
    public var maxRespawns: Int
    /// Before resuming at daemon start: the session file must have been unchanged this long (an omp of the previous
    /// daemon may still be writing its teardown).
    public var resumeQuietPeriod: Duration
    /// After a wake: how long a busy main agent may go without progress (model stream, tool, turn events) before its
    /// turn is aborted and it is told to continue.
    public var wakeStallTimeout: Duration

    public init(
        hello: Duration = .seconds(30), bridgeCall: Duration = .seconds(30), stop: Duration = .seconds(15),
        hangup: Duration = .seconds(3), healthCheck: Duration = .seconds(10), respawnWindow: Duration = .seconds(60),
        maxRespawns: Int = 3, resumeQuietPeriod: Duration = .seconds(1), wakeStallTimeout: Duration = .seconds(120)
    ) {
        self.hello = hello
        self.bridgeCall = bridgeCall
        self.stop = stop
        self.hangup = hangup
        self.healthCheck = healthCheck
        self.respawnWindow = respawnWindow
        self.maxRespawns = maxRespawns
        self.resumeQuietPeriod = resumeQuietPeriod
        self.wakeStallTimeout = wakeStallTimeout
    }
}

/// Daemon-wide read-only mode: once the manifest cannot be written, running sessions keep
/// going but new ones are refused (they could not be restored after a restart).
public final class ReadOnlyMode: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: false)

    public init() {}

    public var isOn: Bool { state.withLock { $0 } }

    /// Switches read-only mode on. True only for the call that switched it.
    public func trip() -> Bool {
        state.withLock { isOn in
            defer { isOn = true }
            return !isOn
        }
    }
}

/// What every `SessionSupervisor` of a daemon shares.
public struct SupervisorContext: Sendable {
    public var manifest: ManifestPublisher
    public var ptys: PTYPool
    public var bridge: any SessionBridgeLink
    public var locks: any SessionLockProvider
    /// Staged `ide-bridge.ts`, passed to every omp with `-e`; nil runs omp without it.
    public var bridgeExtension: String?
    /// Environment every omp starts from (the daemon's own), before `LaunchSpec.env` and the bridge credentials.
    public var baseEnvironment: [String: String]
    public var timings: SupervisorTimings
    /// Whether ompd wants the sessions paused (no omp IDE window connected).
    public var pauseDemand: PauseDemand
    /// omp's launch broker: named services relaunched after a Regime-B resume.
    public var services: any ServiceControl
    /// A manifest write failed (disk full, I/O error).
    public var persistenceFailed: @Sendable (any Error) -> Void
    /// Delivers a notice to every connected client (`ServerFrame.notice`).
    public var notify: @Sendable (DaemonNotice) -> Void

    public init(
        manifest: ManifestPublisher, ptys: PTYPool, bridge: any SessionBridgeLink, locks: any SessionLockProvider,
        bridgeExtension: String?, baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        timings: SupervisorTimings = SupervisorTimings(), pauseDemand: PauseDemand = PauseDemand(),
        services: any ServiceControl = OmpServiceControl(),
        persistenceFailed: @escaping @Sendable (any Error) -> Void, notify: @escaping @Sendable (DaemonNotice) -> Void
    ) {
        self.manifest = manifest
        self.ptys = ptys
        self.bridge = bridge
        self.locks = locks
        self.bridgeExtension = bridgeExtension
        self.baseEnvironment = baseEnvironment
        self.timings = timings
        self.pauseDemand = pauseDemand
        self.services = services
        self.persistenceFailed = persistenceFailed
        self.notify = notify
    }
}

let supervisorLog = Logger(subsystem: "com.omp-ide.ompd", category: "supervisor")
