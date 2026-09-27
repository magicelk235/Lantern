import Darwin
import Foundation
import IDEProtocol
import os
@testable import OmpdCore

struct BridgeTimedOut: Error, CustomStringConvertible {
    let what: String
    var description: String { "timed out waiting for \(what)" }
}

/// Runs `body`, failing with `BridgeTimedOut` instead of hanging the suite.
func bridgeWithin<T: Sendable>(
    _ what: String, seconds: Double = 10, _ body: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw BridgeTimedOut(what: what)
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}

/// Unique socket path well under the 104-byte `sun_path` limit.
func bridgeSocketPath() -> String {
    "/tmp/omb-\(UUID().uuidString.prefix(8).lowercased()).sock"
}

/// Starts a `BridgeServer` on a fresh socket path, runs `body`, and always stops the server.
func withBridgeServer<T>(
    handshakeTimeout: Duration = .seconds(10), _ body: (BridgeServer) async throws -> T
) async throws -> T {
    let server = BridgeServer(socketPath: bridgeSocketPath(), handshakeTimeout: handshakeTimeout)
    try await server.start()
    do {
        let result = try await body(server)
        await server.stop()
        return result
    } catch {
        await server.stop()
        throw error
    }
}

/// Collects `stream` until it finishes.
func bridgeCollect(_ stream: AsyncStream<JSONValue>, seconds: Double = 10) async throws -> [JSONValue] {
    try await bridgeWithin("the event stream to finish", seconds: seconds) {
        var all: [JSONValue] = []
        for await value in stream { all.append(value) }
        return all
    }
}

func bridgePOSIXError(_ code: Int32 = errno) -> POSIXError { POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }

/// Plays the ide-bridge over a blocking POSIX socket (independent of the server's DispatchIO code): sends JSON lines,
/// reads the server's frames, and can hang up.
final class FakeBridge: Sendable {
    private let fd: Int32
    private let inbound = OSAllocatedUnfairLock(initialState: Inbound())

    private struct Inbound: Sendable {
        var buffer: [UInt8] = []
        var lines: [Data] = []
    }

    init(socketPath: String, receiveTimeoutSeconds: Int = 5) throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw bridgePOSIXError() }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: receiveTimeoutSeconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: socketPath.utf8) }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else {
            let code = errno
            Darwin.close(fd)
            throw bridgePOSIXError(code)
        }
        self.fd = fd
    }

    deinit { Darwin.close(fd) }

    func send(_ frame: JSONValue) throws {
        var bytes = try JSONEncoder().encode(frame)
        bytes.append(0x0A)
        try bytes.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                guard written > 0 else { throw bridgePOSIXError() }
                offset += written
            }
        }
    }

    /// A well-formed hello as the real bridge sends it.
    func sendHello(sessionKey: SessionKey, token: String, pid: Int32 = getpid()) throws {
        try send([
            "t": "hello", "v": 1, "sessionKey": .string(sessionKey), "token": .string(token), "pid": .number(Double(pid)),
            "ompVersion": "18.3.1",
            "capabilities": ["session.ensureOnDisk": true, "agent.revive": false],
            "session": [
                "id": "0199aaaa", "file": "/tmp/omb-session.jsonl", "onDisk": false, "leafId": nil, "cwd": "/tmp",
                "artifactsDir": "/tmp/omb-session",
            ],
        ])
    }

    /// A terminal-mode hello (`ptyId` and the terminal's token in place of a session key), as the real bridge sends it.
    func sendTerminalHello(ptyId: PTYID, token: String, pid: Int32 = getpid(), sessionFile: String = "/tmp/omb-terminal.jsonl") throws {
        try send([
            "t": "hello", "v": 1, "ptyId": .string(ptyId), "token": .string(token), "pid": .number(Double(pid)),
            "ompVersion": "18.3.1",
            "capabilities": ["session.shutdown": true, "session.pause": true],
            "session": [
                "id": "0199bbbb", "file": .string(sessionFile), "onDisk": true, "leafId": nil, "cwd": "/tmp",
                "artifactsDir": nil, "title": "typed in a terminal",
            ],
        ])
    }

    /// Sends a hello with `credentials` and returns the server's verdict frame.
    func handshake(_ credentials: BridgeCredentials) async throws -> JSONValue? {
        try sendHello(sessionKey: credentials.sessionKey, token: credentials.token)
        return try await next()
    }

    /// The next frame from the server, or nil once it closed the connection. Throws after the receive timeout.
    func next() async throws -> JSONValue? {
        let line: Data? = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async { [self] in continuation.resume(with: Result { try blockingNextLine() }) }
        }
        guard let line else { return nil }
        return try JSONDecoder().decode(JSONValue.self, from: line)
    }

    /// Hangs up: the server reads end of file.
    func close() {
        shutdown(fd, SHUT_RDWR)
    }

    private func blockingNextLine() throws -> Data? {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            if let line = inbound.withLock({ $0.lines.isEmpty ? nil : $0.lines.removeFirst() }) { return line }
            let count = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count == 0 { return nil }
            guard count > 0 else { throw bridgePOSIXError() }
            let received = Array(chunk[0..<count])
            inbound.withLock { state in
                state.buffer += received
                while let newline = state.buffer.firstIndex(of: 0x0A) {
                    state.lines.append(Data(state.buffer[..<newline]))
                    state.buffer.removeFirst(newline + 1)
                }
            }
        }
    }
}
