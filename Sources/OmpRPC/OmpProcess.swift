import Foundation

/// One `omp --mode rpc|rpc-ui` child speaking the JSONL RPC protocol over its stdio.
///
/// stdout and stderr are drained on a private dispatch queue from the moment the process is spawned,
/// independent of how quickly `output` is consumed. Commands are written in call order; responses
/// are matched to `send` calls by `id`.
public actor OmpProcess {
    public nonisolated let launch: OmpLaunch
    /// Every stdout frame in order (after `rpc_chunk` reassembly, including `ready`, the
    /// `negotiate_protocol` response and every other `response`), stderr text, then `.exited`,
    /// after which the stream finishes. Supports one consumer; buffering is unbounded.
    public nonisolated let output: AsyncStream<OmpOutput>

    private let io: OmpChildIO
    private var process: Process?
    private var started = false
    private var requestCount = 0

    public init(launch: OmpLaunch) {
        self.launch = launch
        let (output, continuation) = AsyncStream.makeStream(of: OmpOutput.self, bufferingPolicy: .unbounded)
        self.output = output
        io = OmpChildIO(output: continuation)
    }

    deinit {
        io.abandon()
    }

    /// The child's pid once spawned (kept after exit for diagnostics).
    public var pid: Int32? { io.pid }

    /// Set when stdout broke RPC framing; the child was then sent SIGTERM and every pending request failed.
    public var protocolViolation: OmpRPCError? { io.protocolViolation }

    /// Spawns omp, waits for its `ready` frame, and switches to protocol v2 (lossless `rpc_chunk`
    /// framing) when omp advertises it with limits `RPCFrameDecoder` accepts. If omp refuses the
    /// switch, the session stays on v1. On any failure after the spawn the child is killed (SIGKILL).
    /// - Parameter readyTimeout: how long to wait for `ready` before failing with `.timeout`.
    public func start(negotiateV2: Bool = true, readyTimeout: Duration = .seconds(30)) async throws -> OmpReady {
        guard !started else { throw OmpRPCError.alreadyStarted }
        started = true
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launch.executable)
        process.arguments = launch.arguments
        process.environment = launch.environment
        process.currentDirectoryURL = URL(fileURLWithPath: launch.currentDirectory, isDirectory: true)
        try io.launch(process)
        self.process = process
        do {
            var ready = try OmpReady(frame: try await awaitReady(timeout: readyTimeout))
            if negotiateV2, ready.canNegotiateV2(
                maxFrameBytes: RPCFrameDecoder.defaultMaxFrameBytes,
                maxReassembledBytes: RPCFrameDecoder.defaultMaxReassembledBytes
            ) {
                do {
                    let response = try await send([
                        "type": .string(OmpCommandName.negotiateProtocol.rawValue),
                        "protocolVersion": 2,
                    ])
                    if JSONValue.safeInteger(response["data"]?["protocolVersion"]) == 2 { ready.protocolVersion = 2 }
                } catch OmpRPCError.commandFailed {
                    // omp declined: v1 framing stays in effect.
                }
            }
            return ready
        } catch {
            io.signal(SIGKILL)
            throw error
        }
    }

    /// Sends one command and returns its `response` frame. A fresh `id` replaces any `id` in
    /// `command`. `success: false` throws `.commandFailed`. `prompt`/`abort_and_prompt` return
    /// their immediate acknowledgement; the `prompt_result` arrives later on `output`.
    /// Cancelling the calling task stops the wait (the command is already written).
    public func send(_ command: JSONValue) async throws -> JSONValue {
        guard process != nil else { throw OmpRPCError.notRunning }
        guard case .object(var fields) = command, case .string(let type)? = fields["type"] else {
            throw OmpRPCError.invalidCommand("a command is a JSON object with a string \"type\"")
        }
        requestCount += 1
        let id = "req_\(requestCount)"
        fields["id"] = .string(id)
        let response = try await io.request(id: id, line: Self.encodeLine(.object(fields)))
        guard response["success"] == .bool(true) else {
            throw OmpRPCError.commandFailed(
                command: response["command"]?.stringValue ?? type,
                message: response["error"]?.stringValue ?? "",
                response: response
            )
        }
        return response
    }

    /// Writes a frame that omp does not answer: `extension_ui_response`, `host_tool_update`,
    /// `host_tool_result`, `host_uri_result` (see `OmpHostReplyType`).
    public func sendNoReply(_ object: JSONValue) throws {
        guard process != nil else { throw OmpRPCError.notRunning }
        guard case .object(let fields) = object, case .string? = fields["type"] else {
            throw OmpRPCError.invalidCommand("a frame is a JSON object with a string \"type\"")
        }
        try io.post(Self.encodeLine(object))
    }

    /// Closes stdin after queued writes are flushed. omp then drains accepted commands, disposes the
    /// session, and exits 0; `output` keeps delivering until then.
    public func closeStdin() {
        io.closeStdin()
    }

    /// Sends `sig` to the child unless it has already been reaped.
    public func signal(_ sig: Int32) {
        io.signal(sig)
    }

    /// Returns once the child has exited and all of its output was delivered to `output`.
    public func waitForExit() async -> OmpExit {
        await io.waitForExit()
    }

    private func awaitReady(timeout: Duration) async throws -> JSONValue {
        let io = io
        let timer = Task.detached {
            try? await Task.sleep(for: timeout)
            if !Task.isCancelled { io.failReady(OmpRPCError.timeout) }
        }
        defer { timer.cancel() }
        return try await io.awaitReady()
    }

    static func encodeLine(_ value: JSONValue) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        var line: Data
        do {
            line = try encoder.encode(value)
        } catch {
            throw OmpRPCError.invalidCommand("not encodable as JSON: \(error)")
        }
        line.append(0x0A)
        return line
    }
}
