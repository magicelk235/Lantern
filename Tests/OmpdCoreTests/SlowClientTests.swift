import Darwin
import Foundation
import IDEProtocol
import IDETransport
import os
import Testing

@testable import OmpdCore

/// A Lantern that stops reading its socket (stopped in a debugger, hung, starved) holds nothing up: ompd reads every PTY
/// as fast as its program writes, never cuts the client off for it (so its window keeps the sessions running), and the
/// client catches up from the screen as it is when it reads again.
@Suite(.timeLimit(.minutes(2)))
struct SlowClientTests {
    @Test func aWindowThatStopsReadingStallsNoProgramOrSessionAndCatchesUpFromTheCurrentScreen() async throws {
        let fixture = try await DaemonFixture(pauseGrace: .milliseconds(300), clientBehindBytes: 256 * 1024)
        let window = try await RawWindow.connect(fixture)
        let session = try await window.call(SessionCreate.self, .init(workspace: fixture.workspace, cols: 100, rows: 30))
        let status = try await fixture.client(.cli)
        try await status.waitForStatus(session.sessionKey, .idle)
        // About 1.5 MB of output, then the program exits.
        let pty = try await window.call(PTYOpen.self, .init(
            cwd: fixture.workspace, command: ["/bin/sh", "-c", "sleep 0.3; seq 1 200000; echo the-end"], cols: 80, rows: 24))
        _ = try await window.call(PTYAttach.self, .init(ptyId: pty.ptyId))

        // The window reads nothing from here on. The program still runs to its end, and ompd's terminal has all of it.
        try await eventually("the program's exit", timeout: .seconds(60)) {
            try await status.client.call(PTYList.self, Empty()).ptys.first { $0.ptyId == pty.ptyId }?.running == false
        }
        let screen = String(decoding: try await status.client.call(PTYAttach.self, .init(ptyId: pty.ptyId)).screen, as: UTF8.self)
        #expect(screen.contains("200000") && screen.contains("the-end"))
        // The window still counts as open: nothing is paused, however long it stays stalled.
        try await Task.sleep(for: .seconds(1))
        #expect(await !fixture.bridge.calls.contains("session.pause"))
        #expect(try await status.entry(session.sessionKey).status == .idle)

        // Reading again: some of the output, then the end of the stream instead of the rest. The connection is still
        // there, and attaching again brings the screen as it is now.
        var received = 0
        reading: while true {
            switch try #require(try await window.next(), "ompd cut the window off") {
            case .ptyOutput(let output) where output.ptyId == pty.ptyId: received += output.data.count
            case .ptyBehind(let behind) where behind.ptyId == pty.ptyId: break reading
            default: continue
            }
        }
        #expect(received < 1_000_000, "what ompd queued for the stalled window is bounded: \(received) bytes")
        let caughtUp = String(decoding: try await window.call(PTYAttach.self, .init(ptyId: pty.ptyId)).screen, as: UTF8.self)
        #expect(caughtUp.contains("200000") && caughtUp.contains("the-end"))

        await status.close()
        await fixture.daemon.shutdown()
    }
}

/// A Lantern window (`app`, a window open) over a plain blocking socket, so that it can simply stop reading: frames are
/// read only by `next` and `call`.
private final class RawWindow: Sendable {
    private let fd: Int32
    private let inbound = OSAllocatedUnfairLock(initialState: Inbound())
    private let lastRequest = OSAllocatedUnfairLock(initialState: 0)

    private struct Inbound: Sendable {
        var decoder = FrameDecoder()
        var ready: [Data] = []
    }

    private init(fd: Int32) {
        self.fd = fd
    }

    deinit { Darwin.close(fd) }

    static func connect(_ fixture: DaemonFixture) async throws -> RawWindow {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 20, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: fixture.paths.socket.path(percentEncoded: false).utf8) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else {
            Darwin.close(fd)
            throw POSIXError(.ECONNREFUSED)
        }
        let window = RawWindow(fd: fd)
        try window.send(.hello(Hello(clientVersion: "raw-window", token: fixture.token, clientKind: .app, hasWindow: true)))
        guard case .welcome? = try await window.next() else { throw Timeout(what: "the welcome") }
        return window
    }

    /// Sends a request and reads up to its response, dropping the pushes read on the way.
    func call<M: DaemonMethod>(_ method: M.Type, _ params: M.Params) async throws -> M.Result {
        let id = "raw-\(lastRequest.withLock { $0 += 1; return $0 })"
        try send(.request(Request(id: id, method: M.name, params: try JSONValue(encoding: params))))
        while let frame = try await next() {
            guard case .response(let response) = frame, response.id == id else { continue }
            if let error = response.error { throw error }
            return try IDECoding.decoder().decode(M.Result.self, from: IDECoding.encoder().encode(response.result ?? .null))
        }
        throw Timeout(what: "the response to \(M.name) (connection closed)")
    }

    /// The next frame; nil once ompd closed the connection.
    func next() async throws -> ServerFrame? {
        let payload: Data? = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async { [self] in continuation.resume(with: Result { try nextPayload() }) }
        }
        return try payload.map { try IDECoding.decoder().decode(ServerFrame.self, from: $0) }
    }

    private func send(_ frame: ClientFrame) throws {
        try FrameCodec.encode(frame).withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                guard written > 0 else { throw POSIXError(.EPIPE) }
                offset += written
            }
        }
    }

    private func nextPayload() throws -> Data? {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            if let payload = inbound.withLock({ $0.ready.isEmpty ? nil : $0.ready.removeFirst() }) { return payload }
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count == 0 { return nil }
            guard count > 0 else { throw POSIXError(errno == EAGAIN ? .ETIMEDOUT : .EIO) }
            let chunk = Data(buffer[0 ..< count])
            try inbound.withLock { $0.ready += try $0.decoder.push(chunk) }
        }
    }
}
