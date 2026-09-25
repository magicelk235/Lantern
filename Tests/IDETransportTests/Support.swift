import Darwin
import Foundation
import IDETransport
import os

let testToken = "3f1c9a7e5b2d4c6a8e0f1a3b5c7d9e1f"
let testStartedAt = Date(timeIntervalSince1970: 1_700_000_000)

/// Unique socket path well under the 104-byte `sun_path` limit.
func tempSocketPath() -> String {
    "/tmp/ompd-test-\(UUID().uuidString.prefix(8).lowercased()).sock"
}

func manifestEntry(_ key: SessionKey) -> SessionManifestEntry {
    SessionManifestEntry(
        sessionKey: key, workspace: "/tmp/workspace",
        launch: LaunchSpec(ompPath: "/opt/homebrew/bin/omp", ompVersion: "18.3.1"), createdAt: testStartedAt)
}

struct TimedOut: Error, CustomStringConvertible {
    let what: String
    var description: String { "timed out waiting for \(what)" }
}

/// Runs `body`, failing with `TimedOut` instead of hanging the suite.
func within<T: Sendable>(_ what: String, timeout seconds: Double = 10, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw TimedOut(what: what)
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}

/// Handler used by every server test: requests go through `router`, the welcome manifest comes from `welcome`, and
/// `connectionClosed` calls are recorded in `closed`.
final class TestHandler: IDERequestHandler {
    let router = IDERouter()
    let closed = Recorder<UUID>()
    private let welcome: @Sendable () async -> [SessionManifestEntry]

    init(welcome: @escaping @Sendable () async -> [SessionManifestEntry] = { [] }) {
        self.welcome = welcome
    }

    func sessionsForWelcome() async -> [SessionManifestEntry] { await welcome() }
    func handle(_ request: Request, from connection: IDEConnection) async -> Response { await router.route(request, from: connection) }
    func connectionClosed(_ connection: IDEConnection) async { await closed.append(connection.id) }

    /// Waits until `connectionClosed` has been called `count` times in total.
    func waitForClosed(count: Int = 1) async throws {
        let closed = closed
        try await within("\(count) connectionClosed call(s)") {
            while await closed.values.count < count { try await Task.sleep(for: .milliseconds(10)) }
        }
    }
}

/// Starts a server on a fresh socket path, runs `body`, and always stops the server.
func withServer<T>(
    _ handler: TestHandler, maxBacklogBytes: Int = IDEServer.defaultMaxBacklogBytes,
    _ body: (IDEServer, String) async throws -> T
) async throws -> T {
    let path = tempSocketPath()
    let server = IDEServer(
        socketPath: path, token: testToken, daemonVersion: "ompd-test", startedAt: testStartedAt, handler: handler,
        maxBacklogBytes: maxBacklogBytes)
    try await server.start()
    do {
        let result = try await body(server, path)
        await server.stop()
        return result
    } catch {
        await server.stop()
        throw error
    }
}

/// One-shot latch: `wait()` suspends until `open()`.
actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }
}

actor Recorder<Value: Sendable> {
    private(set) var values: [Value] = []
    func append(_ value: Value) { values.append(value) }
}

/// The next push the client receives.
func nextPush(_ client: IDEClient) async throws -> ServerFrame {
    let pushes = client.pushes
    return try await within("a push") {
        for await frame in pushes { return frame }
        throw TimedOut(what: "a push (stream finished)")
    }
}

func connectedClient(_ path: String) async throws -> IDEClient {
    let client = IDEClient(socketPath: path, token: testToken, clientVersion: "app-test")
    _ = try await client.connect()
    return client
}

/// Runs blocking socket I/O on a dispatch thread instead of the cooperative pool.
func offPool<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global().async { continuation.resume(with: Result(catching: body)) }
    }
}

func posixError(_ code: Int32 = errno) -> POSIXError { POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }

/// Protocol-level peer over a blocking POSIX socket: sends and reads raw frames, and can simply stop reading.
final class RawClient: Sendable {
    private let fd: Int32
    private let inbound = OSAllocatedUnfairLock(initialState: Inbound())

    private struct Inbound: Sendable {
        var decoder = FrameDecoder()
        var ready: [Data] = []
    }

    init(path: String, receiveTimeoutSeconds: Int = 10) throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw posixError() }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: receiveTimeoutSeconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path.utf8) }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else {
            let code = errno
            Darwin.close(fd)
            throw posixError(code)
        }
        self.fd = fd
    }

    deinit { Darwin.close(fd) }

    func send(_ frame: ClientFrame) throws {
        let bytes = try FrameCodec.encode(frame)
        try bytes.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                guard written > 0 else { throw posixError() }
                offset += written
            }
        }
    }

    /// Sends a hello and returns the welcome.
    func handshake(token: String = testToken) async throws -> Welcome {
        try send(.hello(Hello(clientVersion: "raw-test", token: token)))
        guard case .welcome(let welcome)? = try await next() else { throw TimedOut(what: "welcome") }
        return welcome
    }

    /// Next frame, or nil once the server closed the socket. Throws if nothing arrives within the receive timeout.
    func next() async throws -> ServerFrame? {
        guard let payload = try await offPool({ [self] in try blockingNextPayload() }) else { return nil }
        return try IDECoding.decoder().decode(ServerFrame.self, from: payload)
    }

    /// Reads until the server closes the socket; returns the number of bytes read.
    func readToEOF() async throws -> Int {
        try await offPool { [self] in
            var total = 0
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
                if count == 0 { return total }
                guard count > 0 else { throw posixError() }
                total += count
            }
        }
    }

    private func blockingNextPayload() throws -> Data? {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            if let payload = inbound.withLock({ $0.ready.isEmpty ? nil : $0.ready.removeFirst() }) { return payload }
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count == 0 { return nil }
            guard count > 0 else { throw posixError() }
            let chunk = Data(buffer[0 ..< count])
            try inbound.withLock { $0.ready += try $0.decoder.push(chunk) }
        }
    }
}

// MARK: - Test-only daemon methods

enum Echo: DaemonMethod {
    static let name = "test.echo"
    struct Params: Codable, Sendable {
        var value: Int
        var delayMillis: Int
    }
    typealias Result = Int
}

/// Pushes `count` journal events for `sessionKey` with seq 1...count.
enum EmitEvents: DaemonMethod {
    static let name = "test.emitEvents"
    struct Params: Codable, Sendable {
        var sessionKey: SessionKey
        var count: Int
    }
    typealias Result = Empty
}

/// Pushes `frames` PTY output frames of `bytesPerFrame` bytes, optionally pacing with `waitForBacklog(atMost:)`.
enum Flood: DaemonMethod {
    static let name = "test.flood"
    struct Params: Codable, Sendable {
        var frames: Int
        var bytesPerFrame: Int
        var pacedAtMost: Int?
    }
    typealias Result = Empty
}
