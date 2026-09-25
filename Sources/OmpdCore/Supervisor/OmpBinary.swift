import Darwin
import Foundation
import os

/// Failure to find or identify the omp executable.
public enum OmpBinaryError: Error, Sendable, Equatable, CustomStringConvertible {
    /// No usable omp executable; lists every path that was checked.
    case notFound(searched: [String])
    /// `omp --version` could not be started.
    case launchFailed(String)
    /// `omp --version` failed or printed no recognizable version.
    case versionUnavailable(String)
    /// `omp --version` did not finish in time (it was killed).
    case timeout

    public var description: String {
        switch self {
        case .notFound(let searched): "omp executable not found (searched \(searched.joined(separator: ", ")))"
        case .launchFailed(let reason): "could not launch omp: \(reason)"
        case .versionUnavailable(let reason): "omp version unavailable: \(reason)"
        case .timeout: "omp --version timed out"
        }
    }
}

/// Finds the omp executable and reads its version (pinned into every session's `LaunchSpec`).
enum OmpBinary {
    /// Homebrew's link on Apple Silicon; the fallback when neither `OMP_BIN` nor `PATH` provides omp
    /// (launchd agents start with a minimal `PATH`).
    static let homebrewPath = "/opt/homebrew/bin/omp"

    /// Resolves the omp executable against `environment` (`OMP_BIN`, `PATH`), first match wins: `explicit`,
    /// `$OMP_BIN`, `omp` on `$PATH`, `homebrewPath`. An explicit path or `$OMP_BIN` that is not an executable file is
    /// an error rather than a reason to fall back.
    static func locate(explicit: String?, environment: [String: String]) throws -> String {
        var searched: [String] = []
        func isUsable(_ path: String) -> Bool {
            searched.append(path)
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue
                && FileManager.default.isExecutableFile(atPath: path)
        }
        for configured in [explicit, environment["OMP_BIN"]] {
            guard let configured, !configured.isEmpty else { continue }
            let path = absolutePath(configured)
            guard isUsable(path) else { throw OmpBinaryError.notFound(searched: searched) }
            return path
        }
        for directory in (environment["PATH"] ?? "").split(separator: ":") {
            let path = absolutePath(String(directory) + "/omp")
            if isUsable(path) { return path }
        }
        if isUsable(homebrewPath) { return homebrewPath }
        throw OmpBinaryError.notFound(searched: searched)
    }

    /// Runs `<path> --version` and returns the version it reports (`omp/18.3.1` → `"18.3.1"`).
    /// Fails with `.timeout` if the command has not finished within `timeout` (it is then killed).
    static func version(at path: String, timeout: Duration = .seconds(30)) async throws -> String {
        let (reason, status, stdout) = try await run(path, arguments: ["--version"], timeout: timeout)
        guard reason == .exit, status == 0 else {
            let ending = reason == .exit ? "exit code \(status)" : "signal \(status)"
            throw OmpBinaryError.versionUnavailable("`\(path) --version` ended with \(ending)")
        }
        guard let version = parseVersion(stdout) else {
            throw OmpBinaryError.versionUnavailable("unrecognized `omp --version` output: \(stdout.prefix(200))")
        }
        return version
    }

    /// `omp/1.2.3` → `1.2.3`; otherwise the first `x.y.z[-pre][+build]` in `text`.
    static func parseVersion(_ text: String) -> String? {
        if let match = text.firstMatch(of: /omp\/(\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.+-]*)?)/) { return String(match.1) }
        if let match = text.firstMatch(of: /\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.+-]*)?/) { return String(match.0) }
        return nil
    }

    private static func absolutePath(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        let url = expanded.hasPrefix("/")
            ? URL(fileURLWithPath: expanded)
            : URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(expanded)
        return url.standardizedFileURL.path
    }

    /// Runs a short-lived command (stdin and stderr on /dev/null) and returns how it ended and its stdout.
    /// Output beyond the pipe buffer (64 KiB) blocks the command until the timeout kills it.
    private static func run(
        _ path: String, arguments: [String], timeout: Duration
    ) async throws -> (Process.TerminationReason, Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let stdout = Pipe()
        process.standardOutput = stdout
        let (exits, exited) = AsyncStream.makeStream(of: (Process.TerminationReason, Int32).self)
        process.terminationHandler = {
            exited.yield(($0.terminationReason, $0.terminationStatus))
            exited.finish()
        }
        do {
            try process.run()
        } catch {
            throw OmpBinaryError.launchFailed(error.localizedDescription)
        }
        let timedOut = OSAllocatedUnfairLock(initialState: false)
        let timer = Task.detached {
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            timedOut.withLock { $0 = true }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        var ending: (Process.TerminationReason, Int32)?
        for await status in exits { ending = status }
        timer.cancel()
        guard let ending else {
            // The stream only ends without a status when this task was cancelled.
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            throw CancellationError()
        }
        if timedOut.withLock({ $0 }) { throw OmpBinaryError.timeout }

        // The command is gone, so everything it printed is already in the pipe.
        let fd = stdout.fileHandleForReading.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var output: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            guard count > 0 else { break }
            output.append(contentsOf: buffer[..<count])
        }
        return (ending.0, ending.1, String(decoding: output, as: UTF8.self))
    }
}
