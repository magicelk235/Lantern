import Foundation
import JSONRPC
import os

/// A language server process and the JSON-RPC channel over its stdin and stdout. Writes go through one serial queue,
/// whole messages at a time and in the order they were asked for (JSON-RPC's session hands each write to an
/// unstructured task, so two may run at once); a server that is gone makes a write fail with `EPIPE` instead of raising
/// `SIGPIPE`, which would kill the app. The last few KiB of its stderr are kept to say why it ended.
///
/// `@unchecked Sendable`: of the `Process` only `terminate()`, `isRunning` and the pid are used after launch, which
/// Foundation allows from any thread; everything else is immutable or behind a lock.
final class ServerProcess: @unchecked Sendable {
    let channel: DataChannel
    private let process: Process
    private let stderrTail: OSAllocatedUnfairLock<Data>
    private static let stderrLimit = 4096

    private init(process: Process, channel: DataChannel, stderrTail: OSAllocatedUnfairLock<Data>) {
        self.process = process
        self.channel = channel
        self.stderrTail = stderrTail
    }

    /// Starts `command` in `directory` with `environment`. `exited` is called once when the process ends, with how.
    static func launch(
        _ command: LanguageServerCommand, environment: [String: String], directory: String,
        exited: @escaping @Sendable (Process.TerminationReason, Int32) -> Void
    ) throws -> ServerProcess {
        let process = Process()
        process.executableURL = URL(filePath: command.executable)
        process.arguments = command.arguments
        process.environment = environment
        process.currentDirectoryURL = URL(filePath: directory, directoryHint: .isDirectory)
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        let (data, received) = AsyncStream.makeStream(of: Data.self)
        output.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                received.finish()
            } else {
                received.yield(chunk)
            }
        }
        let tail = OSAllocatedUnfairLock(initialState: Data())
        errors.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            tail.withLock { tail in
                tail.append(chunk)
                if tail.count > stderrLimit { tail.removeFirst(tail.count - stderrLimit) }
            }
        }
        process.terminationHandler = { process in
            exited(process.terminationReason, process.terminationStatus)
        }

        let writer = input.fileHandleForWriting
        _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
        let writes = DispatchQueue(label: "omp-ide.language-server.writes")
        let channel = DataChannel(
            writeHandler: { message in
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    writes.async {
                        do {
                            try writer.write(contentsOf: message)
                            continuation.resume()
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }
                }
            },
            dataSequence: data)

        do {
            try process.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
            received.finish()
            throw error
        }
        return ServerProcess(process: process, channel: channel, stderrTail: tail)
    }

    var processIdentifier: Int32 { process.processIdentifier }

    var isRunning: Bool { process.isRunning }

    /// The last line the process wrote to stderr, if any.
    var lastError: String? {
        let text = String(decoding: stderrTail.withLock { $0 }, as: UTF8.self)
        return text.split(whereSeparator: \.isNewline).last.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    func terminate() {
        if process.isRunning { process.terminate() }
    }

    func kill() {
        if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
    }
}
