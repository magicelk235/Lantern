import Foundation

/// How to spawn one `omp --mode rpc|rpc-ui` process.
public struct OmpLaunch: Sendable, Equatable {
    /// Absolute path of the omp executable (see `OmpBinary.locate`).
    public var executable: String
    public var arguments: [String]
    /// The child's complete environment; nothing is inherited implicitly.
    public var environment: [String: String]
    public var currentDirectory: String

    public init(
        executable: String,
        arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        currentDirectory: String
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.currentDirectory = currentDirectory
    }
}

/// Everything an `OmpProcess` observes, in order.
public enum OmpOutput: Sendable, Equatable {
    /// One logical stdout frame (after `rpc_chunk` reassembly), including `ready` and every `response`.
    case frame(JSONValue)
    /// stderr text, split at line ends (a line longer than 64 KiB is delivered in pieces).
    case stderr(String)
    /// The process ended; always the last element before the stream finishes.
    case exited(OmpExit)
}

/// How the process ended: `code` for a normal exit, `signal` when killed by a signal.
/// Both are nil when the executable could not be spawned at all.
public struct OmpExit: Sendable, Equatable, Hashable, CustomStringConvertible {
    public var code: Int32?
    public var signal: Int32?

    public init(code: Int32?, signal: Int32?) {
        self.code = code
        self.signal = signal
    }

    init(_ process: Process) {
        switch process.terminationReason {
        case .uncaughtSignal: self.init(code: nil, signal: process.terminationStatus)
        default: self.init(code: process.terminationStatus, signal: nil)
        }
    }

    public var description: String {
        if let signal { return "signal \(signal)" }
        if let code { return "exit code \(code)" }
        return "not spawned"
    }
}

/// omp's startup `ready` frame, plus the protocol actually in effect once `OmpProcess.start` returns.
public struct OmpReady: Sendable, Equatable {
    /// Protocol in effect after `start`: 2 once `negotiate_protocol` succeeded, else the ready frame's version (1).
    public var protocolVersion: Int
    /// `supportedProtocolVersions` as advertised.
    public var supported: [Int]
    /// Advertised physical stdout frame limit.
    public var maxFrameBytes: Int
    /// Advertised limit of one reassembled v2 frame (0 when not advertised).
    public var maxReassembledFrameBytes: Int
    /// The ready frame exactly as received.
    public var raw: JSONValue

    public init(protocolVersion: Int, supported: [Int], maxFrameBytes: Int, maxReassembledFrameBytes: Int, raw: JSONValue) {
        self.protocolVersion = protocolVersion
        self.supported = supported
        self.maxFrameBytes = maxFrameBytes
        self.maxReassembledFrameBytes = maxReassembledFrameBytes
        self.raw = raw
    }

    /// Parses a `ready` frame.
    init(frame: JSONValue) throws {
        guard frame.frameType == OmpEventType.ready.rawValue, let version = JSONValue.safeInteger(frame["protocolVersion"]) else {
            throw OmpRPCError.protocolViolation("malformed ready frame")
        }
        self.init(
            protocolVersion: version,
            supported: frame["supportedProtocolVersions"]?.arrayValue?.compactMap { JSONValue.safeInteger($0) } ?? [version],
            maxFrameBytes: JSONValue.safeInteger(frame["maxFrameBytes"]) ?? RPCFrameDecoder.defaultMaxFrameBytes,
            maxReassembledFrameBytes: JSONValue.safeInteger(frame["maxReassembledFrameBytes"]) ?? 0,
            raw: frame
        )
    }

    /// Whether switching to v2 is safe for a decoder with these limits: omp must support v2, chunk only
    /// frames the decoder accepts as chunked (`byteLength >= maxFrameBytes`), and never reassemble
    /// beyond `maxReassembledBytes`. Otherwise staying on v1 (bounded, lossy fallback) is the safe choice.
    func canNegotiateV2(maxFrameBytes decoderFrameBytes: Int, maxReassembledBytes decoderReassembledBytes: Int) -> Bool {
        supported.contains(2)
            && maxFrameBytes >= decoderFrameBytes
            && maxReassembledFrameBytes > 0
            && maxReassembledFrameBytes <= decoderReassembledBytes
    }
}

public enum OmpRPCError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The process has not been spawned (call `start()`), or spawning failed.
    case notRunning
    /// `start()` was already called on this `OmpProcess`.
    case alreadyStarted
    /// The executable could not be spawned.
    case launchFailed(String)
    /// The process ended; pending and later requests fail with its exit status.
    case exited(OmpExit)
    /// `closeStdin()` was called; nothing more can be written.
    case stdinClosed
    /// Writing to omp's stdin failed with this errno.
    case writeFailed(errno: Int32)
    /// omp answered `success: false`; `response` is the whole failure frame (a machine-readable
    /// `code`, when present, is `response["code"]`).
    case commandFailed(command: String, message: String, response: JSONValue)
    /// stdout broke RPC framing (malformed JSONL or an invalid `rpc_chunk` sequence). `OmpProcess`
    /// stops decoding, fails every pending request, and sends SIGTERM to the child.
    case protocolViolation(String)
    /// omp did not emit `ready` in time (the child is killed), or `omp --version` hung.
    case timeout
    /// The value given to `send`/`sendNoReply` is not a JSON object with a string `type`, or is not encodable.
    case invalidCommand(String)
    /// No usable omp executable; lists every path that was checked.
    case binaryNotFound(searched: [String])
    /// `omp --version` failed or printed no recognizable version.
    case versionUnavailable(String)

    public var description: String {
        switch self {
        case .notRunning: "omp is not running"
        case .alreadyStarted: "omp process was already started"
        case .launchFailed(let reason): "could not launch omp: \(reason)"
        case .exited(let exit): "omp exited (\(exit))"
        case .stdinClosed: "omp stdin is closed"
        case .writeFailed(let errno): "writing to omp stdin failed: \(String(cString: strerror(errno)))"
        case .commandFailed(let command, let message, _): "omp command \(command) failed: \(message)"
        case .protocolViolation(let reason): "omp RPC protocol violation: \(reason)"
        case .timeout: "timed out waiting for omp"
        case .invalidCommand(let reason): "invalid omp command: \(reason)"
        case .binaryNotFound(let searched): "omp executable not found (searched \(searched.joined(separator: ", ")))"
        case .versionUnavailable(let reason): "omp version unavailable: \(reason)"
        }
    }
}

extension JSONValue {
    /// `value` as an `Int` when it is an integral number within ±(2^53 − 1) (`Number.isSafeInteger`).
    static func safeInteger(_ value: JSONValue?) -> Int? {
        guard case .number(let number)? = value, number.rounded(.towardZero) == number,
              abs(number) <= 9_007_199_254_740_991
        else { return nil }
        return Int(number)
    }
}
