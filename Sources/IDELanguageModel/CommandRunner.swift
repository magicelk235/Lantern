import Foundation

/// Runs a short command and collects its standard output, killing it when it outlasts its time (a login shell whose rc
/// files wait for a terminal, an `xcrun` stuck on a prompt). Standard input and error are `/dev/null`. The output is
/// read once the command exits, so a process it left behind holding the pipe (an agent a shell started) cannot keep
/// the read waiting; output beyond the pipe's buffer (64 KiB) blocks the command until it times out.
enum CommandRunner {
    /// What the command printed and its exit status; nil when it could not start or ran out of time.
    static func run(
        _ executable: String, _ arguments: [String], environment: [String: String], timeout: Duration
    ) async -> (status: Int32, output: Data)? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: runBlocking(executable, arguments, environment: environment, timeout: timeout))
            }
        }
    }

    /// The command's first line of output, when it exits with 0 within 10 s. Blocks: call it off the main thread.
    static func output(_ executable: String, _ arguments: [String], environment: [String: String]) -> String? {
        guard let (status, output) = runBlocking(executable, arguments, environment: environment, timeout: .seconds(10)),
              status == 0 else { return nil }
        let line = String(decoding: output, as: UTF8.self).split(whereSeparator: \.isNewline).first.map(String.init)
        return line?.isEmpty == false ? line : nil
    }

    private static func runBlocking(
        _ executable: String, _ arguments: [String], environment: [String: String], timeout: Duration
    ) -> (status: Int32, output: Data)? {
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            return nil
        }
        let (seconds, attoseconds) = timeout.components
        guard exited.wait(timeout: .now() + Double(seconds) + Double(attoseconds) / 1e18) == .success else {
            process.terminate()
            if exited.wait(timeout: .now() + 1) != .success { kill(process.processIdentifier, SIGKILL) }
            return nil
        }
        // Everything the command wrote is in the pipe now; read it without waiting for the pipe to close.
        let fd = pipe.fileHandleForReading.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            guard count > 0 else { break }
            output.append(contentsOf: buffer[..<count])
        }
        return (process.terminationStatus, output)
    }
}
