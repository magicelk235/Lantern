import Foundation

/// Incremental decoder for omp's RPC stdout.
///
/// Splits JSONL lines (LF-terminated; a trailing CR and blank or whitespace-only lines are ignored, and
/// a UTF-8 BOM is skipped at the start of the stream), parses each line as one JSON value, and
/// transparently reassembles protocol-v2 `rpc_chunk` sequences. Chunk handling mirrors omp's reference
/// `RpcFrameDecoder` (`packages/coding-agent/src/modes/rpc/rpc-frame.ts`), including its error messages:
/// `chunkId`/`index`/`count`/`byteLength` are validated, sequences must be uninterrupted and in order,
/// `data` must be canonical base64, and the reassembled bytes must be strict UTF-8 holding one JSON object.
///
/// Every violation throws `OmpRPCError.protocolViolation`. The decoder is then out of sync with the
/// stream, so the error is sticky: every later `push`/`finish` rethrows it.
///
/// Tests/OmpRPCTests/Fixtures/conformance.json pins this behaviour to omp's reference client (Bun's
/// JSONL reader feeding `RpcFrameDecoder`). Deliberate differences, none reachable with omp's own
/// output: each line holds exactly one JSON value (Bun also accepts a value spanning lines, and emits
/// the first of several values on one line before failing), lone UTF-16 surrogate escapes decode to
/// U+FFFD, containers nest at most 512 levels, and a stream that ends mid-sequence is a violation.
public struct RPCFrameDecoder: Sendable {
    /// omp's `MAX_RPC_FRAME_BYTES`: the physical stdout frame limit, including the newline.
    public static let defaultMaxFrameBytes = 1 << 20
    /// omp's `MAX_RPC_REASSEMBLED_BYTES`: the largest logical frame protocol v2 reassembles.
    public static let defaultMaxReassembledBytes = 64 << 20
    /// omp's `RPC_CHUNK_PAYLOAD_BYTES`: the most decoded bytes one `rpc_chunk` may carry.
    public static let maxChunkPayloadBytes = 256 << 10
    /// Longest accepted `chunkId`, in UTF-16 code units (JavaScript string length).
    public static let maxChunkIdLength = 128

    /// Chunked frames must declare at least this many bytes (smaller frames are never chunked).
    /// Physical lines longer than this are still accepted: v1 fallback frames can exceed it.
    public let maxFrameBytes: Int
    /// Upper bound for a declared `byteLength`; also the longest physical line accepted.
    public let maxReassembledBytes: Int

    private var partialLine: [UInt8] = []
    private var atStreamStart = true
    private var sequence: ChunkSequence?
    private var chunkBytes: [UInt8] = []
    private var failure: OmpRPCError?

    private struct ChunkSequence: Sendable {
        let chunkId: String
        let count: Int
        let byteLength: Int
        var nextIndex = 0
        var bytes: [UInt8]
    }

    public init(maxFrameBytes: Int = defaultMaxFrameBytes, maxReassembledBytes: Int = defaultMaxReassembledBytes) {
        self.maxFrameBytes = maxFrameBytes
        self.maxReassembledBytes = maxReassembledBytes
    }

    /// True while an `rpc_chunk` sequence has started but not completed.
    public var isReassembling: Bool { sequence != nil }

    /// Decodes `bytes` and returns the complete frames they finish, in stream order.
    /// On a violation the frames decoded earlier in the same call are discarded; use
    /// `push(_:emit:)` to receive them before the error is thrown.
    public mutating func push(_ bytes: Data) throws -> [JSONValue] {
        var frames: [JSONValue] = []
        try bytes.withUnsafeBytes { try push($0) { frames.append($0) } }
        return frames
    }

    /// Decodes `bytes`, handing each complete frame to `emit` as soon as it is decoded, then throws
    /// if the input broke the protocol.
    public mutating func push(_ bytes: UnsafeRawBufferPointer, emit: (JSONValue) -> Void) throws {
        if let failure { throw failure }
        do {
            try consume(bytes, emit: emit)
        } catch let error as OmpRPCError {
            failure = error
            throw error
        }
    }

    /// Ends the stream: decodes a final line that lacks its newline, and fails if a chunk sequence
    /// or line is incomplete.
    public mutating func finish() throws -> [JSONValue] {
        var frames: [JSONValue] = []
        try finish { frames.append($0) }
        return frames
    }

    public mutating func finish(emit: (JSONValue) -> Void) throws {
        if let failure { throw failure }
        do {
            if !partialLine.isEmpty {
                var line: [UInt8] = []
                swap(&line, &partialLine)
                try line.withUnsafeBytes { try handleLine($0, emit: emit) }
            }
            if sequence != nil { throw OmpRPCError.protocolViolation("rpc chunk sequence interrupted") }
        } catch let error as OmpRPCError {
            failure = error
            throw error
        }
    }

    private mutating func consume(_ bytes: UnsafeRawBufferPointer, emit: (JSONValue) -> Void) throws {
        guard let base = bytes.baseAddress else { return }
        var start = 0
        while start < bytes.count {
            guard let newline = memchr(base + start, 0x0A, bytes.count - start) else {
                try appendPartial(UnsafeRawBufferPointer(rebasing: bytes[start...]))
                return
            }
            let end = UnsafeRawPointer(newline) - base
            let segment = UnsafeRawBufferPointer(rebasing: bytes[start..<end])
            if partialLine.isEmpty {
                try handleLine(segment, emit: emit)
            } else {
                try appendPartial(segment)
                var line: [UInt8] = []
                swap(&line, &partialLine)
                defer {
                    line.removeAll(keepingCapacity: true)
                    swap(&line, &partialLine)
                }
                try line.withUnsafeBytes { try handleLine($0, emit: emit) }
            }
            start = end + 1
        }
    }

    private mutating func appendPartial(_ bytes: UnsafeRawBufferPointer) throws {
        guard partialLine.count + bytes.count <= maxReassembledBytes else {
            throw OmpRPCError.protocolViolation("stdout line exceeds \(maxReassembledBytes) bytes")
        }
        partialLine.append(contentsOf: bytes)
    }

    private mutating func handleLine(_ bytes: UnsafeRawBufferPointer, emit: (JSONValue) -> Void) throws {
        var line = bytes
        if atStreamStart {
            atStreamStart = false
            if line.count >= 3, line[0] == 0xEF, line[1] == 0xBB, line[2] == 0xBF {
                line = UnsafeRawBufferPointer(rebasing: line[3...])
            }
        }
        guard line.contains(where: { $0 != 0x20 && $0 != 0x09 && $0 != 0x0D }) else { return }
        guard line.count <= maxReassembledBytes else {
            throw OmpRPCError.protocolViolation("stdout line exceeds \(maxReassembledBytes) bytes")
        }
        let value: JSONValue
        do throws(JSONParseError) {
            value = try JSONParser.parse(line)
        } catch {
            throw OmpRPCError.protocolViolation("invalid JSON on stdout: \(error.reason) at byte \(error.offset)")
        }
        try accept(value, emit: emit)
    }

    private mutating func accept(_ value: JSONValue, emit: (JSONValue) -> Void) throws {
        guard case .object(let fields) = value, fields["type"] == .string(OmpEventType.rpcChunk.rawValue) else {
            if sequence != nil { throw OmpRPCError.protocolViolation("rpc chunk sequence interrupted") }
            guard case .object = value else { throw OmpRPCError.protocolViolation("rpc frame must be an object") }
            emit(value)
            return
        }
        try acceptChunk(fields, emit: emit)
    }

    private mutating func acceptChunk(_ chunk: [String: JSONValue], emit: (JSONValue) -> Void) throws {
        let maxChunkCount = (maxReassembledBytes + Self.maxChunkPayloadBytes - 1) / Self.maxChunkPayloadBytes
        guard case .string(let chunkId)? = chunk["chunkId"], !chunkId.isEmpty, chunkId.utf16.count <= Self.maxChunkIdLength,
              let index = JSONValue.safeInteger(chunk["index"]),
              let count = JSONValue.safeInteger(chunk["count"]),
              let byteLength = JSONValue.safeInteger(chunk["byteLength"]),
              index >= 0, count >= 2, count <= maxChunkCount, index < count,
              byteLength >= maxFrameBytes, byteLength <= maxReassembledBytes
        else { throw OmpRPCError.protocolViolation("invalid rpc chunk metadata") }

        chunkBytes.removeAll(keepingCapacity: true)
        guard case .string(let data)? = chunk["data"], Base64.decodeCanonical(data, into: &chunkBytes) else {
            throw OmpRPCError.protocolViolation("invalid rpc chunk data")
        }
        guard chunkBytes.count <= Self.maxChunkPayloadBytes else {
            throw OmpRPCError.protocolViolation("rpc chunk payload exceeds the transport limit")
        }

        // Move the sequence out of `self` so appending never copies the accumulated bytes.
        var current: ChunkSequence
        if let pending = sequence {
            current = pending
            sequence = nil
        } else {
            guard index == 0 else { throw OmpRPCError.protocolViolation("rpc chunk sequence must start at index 0") }
            var bytes: [UInt8] = []
            bytes.reserveCapacity(byteLength)
            current = ChunkSequence(chunkId: chunkId, count: count, byteLength: byteLength, bytes: bytes)
        }
        guard current.chunkId == chunkId, current.count == count, current.byteLength == byteLength,
              current.nextIndex == index
        else { throw OmpRPCError.protocolViolation("rpc chunk sequence mismatch") }

        current.bytes.append(contentsOf: chunkBytes)
        current.nextIndex += 1
        guard current.bytes.count <= byteLength else {
            throw OmpRPCError.protocolViolation("rpc chunk sequence exceeds declared length")
        }
        guard current.nextIndex == count else {
            sequence = current
            return
        }
        guard current.bytes.count == byteLength else {
            throw OmpRPCError.protocolViolation("rpc chunk sequence length mismatch")
        }

        let frame = try current.bytes.withUnsafeBufferPointer { buffer throws -> JSONValue in
            guard UTF8Validation.isValid(buffer) else {
                throw OmpRPCError.protocolViolation("reassembled rpc frame is not valid UTF-8")
            }
            var json = UnsafeRawBufferPointer(buffer)
            // TextDecoder (without ignoreBOM) drops a leading BOM before JSON.parse sees the text.
            if json.count >= 3, json[0] == 0xEF, json[1] == 0xBB, json[2] == 0xBF {
                json = UnsafeRawBufferPointer(rebasing: json[3...])
            }
            do throws(JSONParseError) {
                return try JSONParser.parse(json)
            } catch {
                throw OmpRPCError.protocolViolation("reassembled rpc frame is not valid JSON: \(error.reason) at byte \(error.offset)")
            }
        }
        guard case .object = frame else { throw OmpRPCError.protocolViolation("rpc frame must be an object") }
        emit(frame)
    }
}
