import Darwin
import Foundation
import IDEProtocol

/// `ompd run`: the daemon process from start to exit.
public enum DaemonRunner {
    public struct Options: Sendable {
        /// omp for new sessions; nil = `OmpBinary.locate` (`$OMP_BIN`, `PATH`, Homebrew).
        public var ompExecutable: String?
        /// Appended to every new session's omp command line (e.g. `--config <overlay>`).
        public var ompArguments: [String]
        /// `--session-dir` for new sessions; nil = omp's default.
        public var sessionDirectory: String?

        public init(ompExecutable: String? = nil, ompArguments: [String] = [], sessionDirectory: String? = nil) {
            self.ompExecutable = ompExecutable
            self.ompArguments = ompArguments
            self.sessionDirectory = sessionDirectory
        }
    }

    /// Runs the daemon until SIGTERM/SIGINT, then takes the graceful path and returns the exit status. Must be called
    /// from an async `main`, which keeps the main queue serviced (the PTY pool runs on the main executor).
    public static func run(_ options: Options, paths: AppSupportPaths = .standard) async throws -> Int32 {
        let environment = ProcessInfo.processInfo.environment
        let instance = try DaemonInstanceLock.acquire(paths)
        console("ompd \(ompdVersion) pid \(getpid()) starting; home \(paths.root.path(percentEncoded: false))")
        try paths.prepare()
        let token = try paths.loadOrCreateToken()
        // Caught (not ignored) so omp children start with default dispositions; SIGPIPE only needs to not kill us.
        let trap = SignalTrap([SIGTERM, SIGINT])
        SignalTrap.catchWithoutAction(SIGPIPE)

        var bridgeExtension: String?
        do {
            bridgeExtension = try BridgeInstaller.stage(into: paths).path(percentEncoded: false)
        } catch {
            console("ide-bridge not staged (\(error)); sessions run without it")
        }
        if environment[AppSupportPaths.homeEnvironmentKey]?.isEmpty ?? true {
            // Lock mode for every other omp on the machine. Skipped for relocated (test) homes.
            do {
                let installed = try BridgeInstaller.installGlobal(agentDir: BridgeInstaller.defaultAgentDir)
                console("lock-mode ide-bridge at \(installed.path(percentEncoded: false))")
            } catch {
                console("lock-mode ide-bridge not installed: \(error)")
            }
        }
        let bridge = BridgeServer(socketPath: paths.bridgeSocket.path(percentEncoded: false))
        try await bridge.start()

        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .automaticTerminationDisabled, .suddenTerminationDisabled],
            reason: "ompd supervises omp sessions and terminals")
        let configuration = Daemon.Configuration(
            paths: paths, ompExecutable: options.ompExecutable, ompArguments: options.ompArguments,
            sessionDirectory: options.sessionDirectory, bridgeExtension: bridgeExtension, baseEnvironment: environment)
        let daemon = Daemon(
            configuration: configuration, token: token, bridge: bridge,
            locks: OwnedSessionLocks(directory: paths.ownedSessions), ptys: PTYPool(snapshotDirectory: paths.ptySnapshots))
        do {
            try await daemon.start()
        } catch {
            await bridge.stop()
            throw error
        }
        console("listening on \(paths.socket.path(percentEncoded: false))")
        let power = PowerObserver(willSleep: { await daemon.prepareForSleep() }, didWake: { await daemon.didWake() })
        do {
            try power.start()
        } catch {
            console("sleep/wake notifications unavailable: \(error)")
        }
        let restore = Task {
            await daemon.restore()
            console("restore finished")
        }

        var signals = trap.signals.makeAsyncIterator()
        let signal = await signals.next() ?? SIGTERM
        console("received \(signal == SIGINT ? "SIGINT" : "SIGTERM"); shutting down")
        power.stop()
        // Pending resumes give up (their quiescence waits end); shutdown then stops whatever did start.
        restore.cancel()
        await daemon.shutdown()
        await restore.value
        await bridge.stop()
        ProcessInfo.processInfo.endActivity(activity)
        withExtendedLifetime(instance) {}
        console("shut down")
        return 0
    }

    /// Lifecycle lines on stderr (the LaunchAgent's log file); details go to the unified log.
    public static func console(_ line: String) {
        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true))
        FileHandle.standardError.write(Data("\(stamp) \(line)\n".utf8))
    }
}
