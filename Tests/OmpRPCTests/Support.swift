import Foundation
import OmpRPC
import Testing

extension Tag {
    /// Spawns the real omp binary (skipped when none is installed).
    @Tag static var integration: Self
}

/// Decodes `bytes` in pieces whose sizes come from `sizes` (cycled), then finishes the stream.
/// Returns the frames emitted before any violation, and the violation.
func decodeStream(
    _ bytes: [UInt8],
    decoder: RPCFrameDecoder = RPCFrameDecoder(),
    pieceSizes sizes: [Int]? = nil
) -> (frames: [JSONValue], error: OmpRPCError?) {
    var decoder = decoder
    var frames: [JSONValue] = []
    do {
        try bytes.withUnsafeBytes { all in
            var offset = 0
            var step = 0
            while offset < all.count {
                let size = sizes.map { $0[step % $0.count] } ?? all.count
                let end = min(all.count, offset + max(1, size))
                try decoder.push(UnsafeRawBufferPointer(rebasing: all[offset..<end])) { frames.append($0) }
                offset = end
                step += 1
            }
        }
        try decoder.finish { frames.append($0) }
        return (frames, nil)
    } catch let error as OmpRPCError {
        return (frames, error)
    } catch {
        Issue.record("unexpected error type: \(error)")
        return (frames, nil)
    }
}

/// `Result(catching:)` for async work.
func capture<T: Sendable>(_ body: @Sendable () async throws -> T) async -> Result<T, any Error> {
    do {
        return .success(try await body())
    } catch {
        return .failure(error)
    }
}

/// Parses JSON text with Foundation (independent of `RPCFrameDecoder`'s parser).
func foundationJSON(_ text: String) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
}

/// omp-style `rpc_chunk` lines (canonical base64, `chunkSize` payload bytes per chunk) for `payload`.
func chunkLines(_ payload: [UInt8], chunkId: String = "rpc-1", chunkSize: Int, byteLength: Int? = nil) -> [String] {
    let count = (payload.count + chunkSize - 1) / chunkSize
    return (0..<count).map { index in
        let slice = payload[(index * chunkSize)..<min(payload.count, (index + 1) * chunkSize)]
        return chunkLine(chunkId: chunkId, index: index, count: count, byteLength: byteLength ?? payload.count, data: Data(slice).base64EncodedString())
    }
}

func chunkLine(chunkId: String, index: Int, count: Int, byteLength: Int, data: String) -> String {
    #"{"type":"rpc_chunk","chunkId":"\#(chunkId)","index":\#(index),"count":\#(count),"byteLength":\#(byteLength),"data":"\#(data)"}"#
}

/// SplitMix64: a deterministic generator for reproducible "random" test inputs.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// A scratch directory under the system temp dir, removed by `remove()`.
struct TemporaryDirectory {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("omprpc-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    var path: String { url.path }

    /// Writes an executable shell script named `name` and returns its path.
    func script(_ name: String, _ body: String) throws -> String {
        let file = url.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ("#!/bin/sh\n" + body).write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        return file.path
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

extension AsyncStream<OmpOutput> {
    /// Collects everything until the stream finishes.
    func collect() async -> [OmpOutput] {
        var all: [OmpOutput] = []
        for await item in self { all.append(item) }
        return all
    }
}

extension [OmpOutput] {
    var frames: [JSONValue] {
        compactMap { if case .frame(let frame) = $0 { frame } else { nil } }
    }

    var stderrText: String {
        map { if case .stderr(let text) = $0 { text } else { "" } }.joined()
    }
}
