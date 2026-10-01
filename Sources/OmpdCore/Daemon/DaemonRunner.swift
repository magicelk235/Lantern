import Darwin
import Foundation
import IDEProtocol

/// `ompd run`: the daemon process from start to exit, and from one image to the next when it
/// upgrades itself in place.
public enum DaemonRunner {
    public struct Options: Sendable {
        /// omp for new sessions; nil = `OmpBinary.locate` (`$OMP_BIN`, `PATH`, Homebrew).
        public var ompExecutable: String?
        /// Appended to every new session's omp command line (e.g. `--config <overlay>`).
        public var ompArguments: [String]
        /// `--session-dir` for new sessions; nil = omp's default.
        public var sessionDirectory: String?
        /// Free space under which ompd warns (`LowSpaceAlarm`); nil = the larger of 1 GiB and 1% of the volume.
        public var lowSpaceThreshold: Int64?
        /// The `run` arguments as given, without `--handover`: what the installed executable is started with when ompd
        /// upgrades itself.
        public var arguments: [String]
        /// `--handover <file>`: this process is the next image of an in-place upgrade and takes over what the file
        /// describes.
        public var handover: String?

        public init(
            ompExecutable: String? = nil, ompArguments: [String] = [], sessionDirectory: String? = nil,
            lowSpaceThreshold: Int64? = nil, arguments: [String] = [], handover: String? = nil
        ) {
            self.ompExecutable = ompExecutable
            self.ompArguments = ompArguments
            self.sessionDirectory = sessionDirectory
            self.lowSpaceThreshold = lowSpaceThreshold
            self.arguments = arguments
            self.handover = handover
        }
    }

    /// Runs the daemon until SIGTERM/SIGINT, then takes the graceful path and returns the exit status. Must be called
    /// from an async `main`, which keeps the main queue serviced (the PTY pool runs on the main executor).
    public static func run(_ options: Options, paths: AppSupportPaths = .standard) async throws -> Int32 {
        let environment = ProcessInfo.processInfo.environment
        let handover = options.handover.flatMap { takeHandover(from: $0, paths: paths) }
        let instance = try handover.flatMap { DaemonInstanceLock(adopting: $0.instanceLock, in: paths) } ?? DaemonInstanceLock.acquire(paths)
        if let handover {
            console("ompd \(ompdVersion) pid \(getpid()) took over from ompd \(handover.fromVersion); home \(paths.root.path(percentEncoded: false))")
        } else {
            console("ompd \(ompdVersion) pid \(getpid()) starting; home \(paths.root.path(percentEncoded: false))")
        }
        // Handed over, `run/` holds the ownership locks still held and the clients' token: it stays.
        try paths.prepare(keepingRun: handover != nil)
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
        if let handover { await bridge.restore(handover.bridge) }
        try await bridge.start()

        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .automaticTerminationDisabled, .suddenTerminationDisabled],
            reason: "ompd supervises omp sessions and terminals")
        let executable = RunningExecutable.current()
        if executable == nil { console("the ompd executable cannot be read; ompd will not upgrade itself") }
        let configuration = Daemon.Configuration(
            paths: paths, ompExecutable: options.ompExecutable, ompArguments: options.ompArguments,
            sessionDirectory: options.sessionDirectory, bridgeExtension: bridgeExtension, baseEnvironment: environment,
            lowSpaceThreshold: options.lowSpaceThreshold,
            process: executable.map {
                RunnerProcess(
                    executable: $0, arguments: [CommandLine.arguments.first ?? "ompd", "run"] + options.arguments,
                    instance: instance, handoverFile: paths.run.appending(path: "handover.json", directoryHint: .notDirectory))
            })
        let daemon = Daemon(
            configuration: configuration, token: token, bridge: bridge,
            locks: OwnedSessionLocks(directory: paths.ownedSessions), ptys: PTYPool(snapshotDirectory: paths.ptySnapshots),
            startedAt: handover?.startedAt ?? Date())
        do {
            try await daemon.start(handover: handover)
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
        // Handed over, nothing needs restoring: the PTYs and omps ran on.
        let restore = Task {
            guard handover == nil else { return }
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

    /// The handover the previous image wrote. When it cannot be read, the descriptors that image kept open for this one
    /// are closed — their PTYs hang up, their locks go — and ompd starts afresh (Regime B2, as after an ompd crash)
    /// rather than leave omps on terminals nobody reads.
    private static func takeHandover(from path: String, paths: AppSupportPaths) -> DaemonHandover? {
        do {
            return try DaemonHandover.take(from: URL(filePath: path))
        } catch {
            console("the handover \(path) cannot be read (\(error)); starting afresh")
            ProcessImage.closeInherited()
            return nil
        }
    }

    /// Lifecycle lines on stderr (the LaunchAgent's log file); details go to the unified log.
    public static func console(_ line: String) {
        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true))
        FileHandle.standardError.write(Data("\(stamp) \(line)\n".utf8))
    }
}

/// `ompd run`'s process: it becomes the ompd installed at its path with `execve`, keeping its pid.
final class RunnerProcess: DaemonProcess {
    let executable: RunningExecutable
    /// The next image's argv: this one's `argv[0]`, `run` and the run arguments.
    let arguments: [String]
    let instance: DaemonInstanceLock
    let handoverFile: URL

    init(executable: RunningExecutable, arguments: [String], instance: DaemonInstanceLock, handoverFile: URL) {
        self.executable = executable
        self.arguments = arguments
        self.instance = instance
        self.handoverFile = handoverFile
    }

    func installedReplacement() async -> InstalledExecutable? {
        await executable.installedReplacement()
    }

    /// Writes the handover (with `ompd.lock`'s descriptor) to `run/handover.json`, keeps exactly the handed-over
    /// descriptors open across the exec, and execs the installed executable with `run <arguments> --handover <file>`.
    func handOver(_ handover: DaemonHandover) -> any Error {
        var handover = handover
        handover.instanceLock = instance.descriptor
        let descriptors = handover.descriptors
        do {
            try handover.write(to: handoverFile)
            try ProcessImage.inherit(descriptors)
        } catch {
            unlink(handoverFile.path(percentEncoded: false))
            return error
        }
        DaemonRunner.console("handing over to \(executable.path) (pid \(getpid()) stays)")
        let code = ProcessImage.replace(with: executable.path, arguments: arguments + ["--handover", handoverFile.path(percentEncoded: false)])
        ProcessImage.closeOnExec(descriptors)
        unlink(handoverFile.path(percentEncoded: false))
        return HandoverError("execve \(executable.path): \(String(cString: strerror(code)))")
    }

    func restart() async {
        DaemonRunner.console("restarting into \(executable.path)")
        let code = ProcessImage.replace(with: executable.path, arguments: arguments)
        DaemonRunner.console("execve \(executable.path) failed (\(String(cString: strerror(code)))); exiting so that launchd starts ompd again")
        exit(1)
    }
}
