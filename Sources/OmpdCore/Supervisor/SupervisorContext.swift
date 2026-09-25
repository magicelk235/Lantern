import Foundation
import IDEProtocol
import os

/// Timeouts of a `SessionSupervisor`.
public struct SupervisorTimings: Sendable {
    /// Spawn to omp's `ready` frame (observed 0.25–0.45 s).
    public var ready: Duration
    /// RPC `ready` to the bridge `hello` (observed ~18 ms). On expiry the session runs without bridge features.
    public var hello: Duration
    /// One bridge call (`session.ensureOnDisk`, …).
    public var bridgeCall: Duration
    /// stdin EOF to exit before stragglers are killed (15 s of launchd's ~20 s).
    public var stop: Duration
    /// Answer to the post-wake `get_state` health check.
    public var healthCheck: Duration

    public init(
        ready: Duration = .seconds(30), hello: Duration = .seconds(10), bridgeCall: Duration = .seconds(30),
        stop: Duration = .seconds(15), healthCheck: Duration = .seconds(10)
    ) {
        self.ready = ready
        self.hello = hello
        self.bridgeCall = bridgeCall
        self.stop = stop
        self.healthCheck = healthCheck
    }
}

/// Daemon-wide read-only mode: once a journal write fails, nothing more is journaled; omp
/// keeps being drained so it never blocks, and work that would need journaling is refused.
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
    public var journalDirectory: URL
    public var bridge: any SessionBridgeLink
    public var locks: any SessionLockProvider
    /// Staged `ide-bridge.ts`, passed to every omp with `-e`; nil runs omp without it.
    public var bridgeExtension: String?
    /// Environment every omp child starts from (the daemon's own), before `LaunchSpec.env` is merged over it.
    public var baseEnvironment: [String: String]
    public var timings: SupervisorTimings
    public var readOnly: ReadOnlyMode
    /// A journal append failed for a reason other than the journal being closed (disk full, I/O error).
    public var journalFailed: @Sendable (SessionKey, any Error) -> Void
    /// Delivers a notice the journal cannot take to every connected client (`ServerFrame.notice`).
    public var notify: @Sendable (DaemonNotice) -> Void

    public init(
        manifest: ManifestPublisher, journalDirectory: URL, bridge: any SessionBridgeLink, locks: any SessionLockProvider,
        bridgeExtension: String?, baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        timings: SupervisorTimings = SupervisorTimings(), readOnly: ReadOnlyMode,
        journalFailed: @escaping @Sendable (SessionKey, any Error) -> Void,
        notify: @escaping @Sendable (DaemonNotice) -> Void
    ) {
        self.manifest = manifest
        self.journalDirectory = journalDirectory
        self.bridge = bridge
        self.locks = locks
        self.bridgeExtension = bridgeExtension
        self.baseEnvironment = baseEnvironment
        self.timings = timings
        self.readOnly = readOnly
        self.journalFailed = journalFailed
        self.notify = notify
    }
}

let supervisorLog = Logger(subsystem: "com.omp-ide.ompd", category: "supervisor")
