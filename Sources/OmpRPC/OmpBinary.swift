import Foundation
import os

/// Finds the omp executable and reads its version.
public enum OmpBinary {
    /// Homebrew's link on Apple Silicon; the fallback when neither `OMP_BIN` nor `PATH` provides omp
    /// (launchd agents start with a minimal `PATH`).
    public static let homebrewPath = "/opt/homebrew/bin/omp"

    /// Resolves the omp executable, first match wins: `explicit`, `$OMP_BIN`, `omp` on `$PATH`,
    /// `homebrewPath`. An explicit path or `$OMP_BIN` that is not an executable file is an error
    /// rather than a reason to fall back.
    public static func locate(explicit: String?) throws -> String {
        try locate(explicit: explicit, environment: ProcessInfo.processInfo.environment)
    }

    /// `locate(explicit:)` against a given environment (`OMP_BIN`, `PATH`).
    public static func locate(explicit: String?, environment: [String: String]) throws -> String {
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
            guard isUsable(path) else { throw OmpRPCError.binaryNotFound(searched: searched) }
            return path
        }
        for directory in (environment["PATH"] ?? "").split(separator: ":") {
            let path = absolutePath(String(directory) + "/omp")
            if isUsable(path) { return path }
        }
        if isUsable(homebrewPath) { return homebrewPath }
        throw OmpRPCError.binaryNotFound(searched: searched)
    }

    /// Runs `<path> --version` and returns the version it reports (`omp/18.3.1` → `"18.3.1"`).
    /// Fails with `.timeout` if the command has not finished within `timeout` (it is then killed).
    public static func version(at path: String, timeout: Duration = .seconds(30)) async throws -> String {
        let (status, stdout) = try await run(path, arguments: ["--version"], timeout: timeout)
        guard status == OmpExit(code: 0, signal: nil) else {
            throw OmpRPCError.versionUnavailable("`\(path) --version` ended with \(status)")
        }
        guard let version = parseVersion(stdout) else {
            throw OmpRPCError.versionUnavailable("unrecognized `omp --version` output: \(stdout.prefix(200))")
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

    /// Runs a short-lived command (stdin and stderr on /dev/null) and returns its exit and stdout.
    /// Output beyond the pipe buffer (64 KiB) blocks the command until the timeout kills it.
    private static func run(_ path: String, arguments: [String], timeout: Duration) async throws -> (OmpExit, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let stdout = Pipe()
        process.standardOutput = stdout
        let (exits, exited) = AsyncStream.makeStream(of: OmpExit.self)
        process.terminationHandler = {
            exited.yield(OmpExit($0))
            exited.finish()
        }
        do {
            try process.run()
        } catch {
            throw OmpRPCError.launchFailed(error.localizedDescription)
        }
        let timedOut = OSAllocatedUnfairLock(initialState: false)
        let timer = Task.detached {
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            timedOut.withLock { $0 = true }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        var exit: OmpExit?
        for await status in exits { exit = status }
        timer.cancel()
        guard let exit else {
            // The stream only ends without a status when this task was cancelled.
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            throw CancellationError()
        }
        if timedOut.withLock({ $0 }) { throw OmpRPCError.timeout }

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
        return (exit, String(decoding: output, as: UTF8.self))
    }
}
