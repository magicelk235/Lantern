import Foundation

/// Runs git in a folder and hands back what it printed. No thread waits for git: its output and its exit arrive
/// through Foundation's handlers while the calling task is suspended. (A run that held a thread of Swift's cooperative
/// pool until git was done starved the pool once a window restored more editor tabs than the Mac has cores, each tab
/// reading HEAD, and every task in the app stalled with it, the connection to ompd among them.) Git never prompts
/// (`GIT_TERMINAL_PROMPT=0`) and never takes the optional index lock a read would.
public enum Git {
    /// git exited with a nonzero status: `stderr` says why.
    public struct Failure: Error, CustomStringConvertible {
        public let arguments: [String]
        public let status: Int32
        public let stderr: String

        /// The stderr, else the exit status.
        public var description: String {
            stderr.isEmpty ? "git \(arguments.first ?? "") exited with status \(status)" : stderr
        }
    }

    /// The git of the active developer directory (`xcode-select -p`), else Homebrew's; nil without either. The
    /// command line tools' `/usr/bin/git` shim is never run, so a Mac without them gets no install prompt.
    public static let executable: String? = {
        var candidates: [String] = []
        if let developer = developerDirectory() { candidates.append(developer + "/usr/bin/git") }
        candidates += ["/opt/homebrew/bin/git", "/usr/local/bin/git"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    /// `git <arguments>` in `directory`; its stdout when it exits 0, else a `Failure` with its stderr.
    public static func output(_ arguments: [String], in directory: String) async throws -> Data {
        guard let executable else { throw Failure(arguments: arguments, status: 127, stderr: "git is not installed") }
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = URL(filePath: directory, directoryHint: .isDirectory)
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        process.environment = environment
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        // Set before the launch: a handler set once git is gone would never run.
        let (exits, exited) = AsyncStream.makeStream(of: Int32.self)
        process.terminationHandler = {
            exited.yield($0.terminationStatus)
            exited.finish()
        }
        do {
            try process.run()
        } catch {
            throw Failure(arguments: arguments, status: 126, stderr: error.localizedDescription)
        }
        // Both pipes drain as their bytes arrive, so a chatty git never stalls on a full pipe.
        let output = chunks(of: stdout.fileHandleForReading)
        let errors = chunks(of: stderr.fileHandleForReading)
        var status: Int32?
        for await code in exits { status = code }
        guard let status else {
            // The stream only ends without a status when this task was cancelled.
            if process.isRunning { process.terminate() }
            throw CancellationError()
        }
        guard status == 0 else {
            throw Failure(
                arguments: arguments, status: status,
                stderr: String(decoding: await joined(errors), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let data = await joined(output)
        // A cancelled task stops reading early: what it has is not all git printed.
        try Task.checkCancellation()
        return data
    }

    /// `git <arguments>` as text, without the trailing line break.
    public static func text(_ arguments: [String], in directory: String) async throws -> String {
        String(decoding: try await output(arguments, in: directory), as: UTF8.self).trimmingCharacters(in: .newlines)
    }

    /// What `handle` delivers until its end, read as it arrives whether or not the stream is iterated yet.
    private static func chunks(of handle: FileHandle) -> AsyncStream<Data> {
        let (chunks, received) = AsyncStream.makeStream(of: Data.self)
        handle.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                received.finish()
            } else {
                received.yield(chunk)
            }
        }
        return chunks
    }

    private static func joined(_ chunks: AsyncStream<Data>) async -> Data {
        var data = Data()
        for await chunk in chunks { data.append(chunk) }
        return data
    }

    private static func developerDirectory() -> String? {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/xcode-select")
        process.arguments = ["-p"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }
}
