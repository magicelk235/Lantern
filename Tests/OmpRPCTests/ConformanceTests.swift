import CryptoKit
import Foundation
import OmpRPC
import Testing

/// Replays Fixtures/conformance.json: streams produced by omp's own `RpcFrameEncoder`, with the verdicts
/// of omp's reference decoder (TypeScript `RpcFrameDecoder` behind Bun's JSONL reader, as `RpcClient`
/// runs them). Regenerate with `BUN_BE_BUN=1 omp run Tests/OmpRPCTests/Fixtures/oracle/generate.ts`.
@Suite("Conformance with omp's reference decoder")
struct ConformanceTests {
    struct Case: Sendable, CustomTestStringConvertible {
        let name: String
        let lines: [JSONValue]
        let sha256: String
        let referenceOK: Bool
        /// Indices into `Fixture.frames` of the frames the reference decoded (before its error, if any).
        let referenceFrames: [Int]
        let referenceError: String?
        /// The reference error came from an `RpcFrameDecoder` rule, so its message must match exactly.
        let referenceErrorIsChunkRule: Bool
        /// The reference accepted the stream but was left mid-sequence at its end.
        let pendingAtEOF: Bool
        var testDescription: String { name }
    }

    struct Fixture: Sendable {
        let base: [[UInt8]]
        let frames: [JSONValue]
        let cases: [Case]
    }

    static let fixture = Result { try loadFixture() }
    static var cases: [Case] { (try? fixture.get().cases) ?? [] }

    @Test func fixtureLoads() throws {
        let fixture = try Self.fixture.get()
        #expect(fixture.cases.count > 50)
        #expect(fixture.cases.contains { $0.name == "stream/golden" })
    }

    @Test(arguments: cases)
    func decodesLikeTheReference(_ testCase: Case) throws {
        let fixture = try Self.fixture.get()
        let bytes = try Self.assemble(testCase.lines, base: fixture.base)
        #expect(hex(SHA256.hash(data: bytes)) == testCase.sha256, "stream rebuilt differently than by the generator")
        let expected = testCase.referenceFrames.map { fixture.frames[$0] }
        check(testCase, expected, decodeStream(bytes))
        if bytes.count < 4096 {
            check(testCase, expected, decodeStream(bytes, pieceSizes: [1]))
        }
    }

    @Test func goldenStreamSurvivesArbitraryReadSizes() throws {
        let fixture = try Self.fixture.get()
        let golden = try #require(fixture.cases.first { $0.name == "stream/golden" })
        let bytes = try Self.assemble(golden.lines, base: fixture.base)
        let expected = golden.referenceFrames.map { fixture.frames[$0] }
        var random = SeededGenerator(seed: 2026)
        for _ in 0..<4 {
            let sizes = (0..<257).map { _ in Int.random(in: 1...70_000, using: &random) }
            check(golden, expected, decodeStream(bytes, pieceSizes: sizes))
        }
    }

    private func check(_ testCase: Case, _ expected: [JSONValue], _ decoded: (frames: [JSONValue], error: OmpRPCError?)) {
        #expect(decoded.frames == expected)
        switch (testCase.referenceOK, decoded.error) {
        case (true, nil) where !testCase.pendingAtEOF:
            break
        case (true, .protocolViolation(let message)?) where testCase.pendingAtEOF:
            // Unlike the reference decoder, RPCFrameDecoder.finish() reports a truncated sequence.
            #expect(message == "rpc chunk sequence interrupted")
        case (false, .protocolViolation(let message)?):
            if testCase.referenceErrorIsChunkRule { #expect(message == testCase.referenceError) }
        default:
            Issue.record("reference: \(testCase.referenceOK ? "ok" : testCase.referenceError ?? "error"); RPCFrameDecoder: \(String(describing: decoded.error))")
        }
    }

    private struct MalformedFixture: Error { let what: String }

    private static func required<T>(_ value: T?, _ what: @autoclosure () -> String) throws -> T {
        guard let value else { throw MalformedFixture(what: what()) }
        return value
    }

    private static func loadFixture() throws -> Fixture {
        // Read from the source tree, so the fixtures need no resource bundle.
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/conformance.json")
        let manifest = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
        let base = try (manifest["base"]?.arrayValue ?? []).map(expand)
        let frames = try (manifest["frames"]?.arrayValue ?? []).map { try foundationJSON(String(decoding: expand($0), as: UTF8.self)) }
        let cases = try (manifest["cases"]?.arrayValue ?? []).map { entry in
            let ts = try required(entry["ts"], "ts verdict")
            let indices = try (ts["frames"]?.arrayValue ?? []).map { index in
                try required(index.intValue.flatMap { frames.indices.contains($0) ? $0 : nil }, "frame index \(index)")
            }
            return Case(
                name: try required(entry["name"]?.stringValue, "case name"),
                lines: entry["lines"]?.arrayValue ?? [],
                sha256: try required(entry["sha256"]?.stringValue, "sha256"),
                referenceOK: ts["ok"] == .bool(true),
                referenceFrames: indices,
                referenceError: ts["error"]?.stringValue,
                referenceErrorIsChunkRule: ts["errorKind"] == .string("chunk"),
                pendingAtEOF: ts["pendingAtEOF"] == .bool(true)
            )
        }
        return Fixture(base: base, frames: frames, cases: cases)
    }

    /// Segments: "text" | [unit, count] | {"bytes": base64}.
    private static func expand(_ segments: JSONValue) throws -> [UInt8] {
        var bytes: [UInt8] = []
        for segment in segments.arrayValue ?? [] {
            switch segment {
            case .string(let text):
                bytes.append(contentsOf: text.utf8)
            case .array(let run):
                let unit = Array(try required(run.first?.stringValue, "run unit").utf8)
                let count = try required(run.last?.intValue, "run count")
                bytes.reserveCapacity(bytes.count + unit.count * count)
                for _ in 0..<count { bytes.append(contentsOf: unit) }
            case .object(let raw):
                bytes.append(contentsOf: try required(raw["bytes"]?.stringValue.flatMap { Data(base64Encoded: $0) }, "raw bytes"))
            default:
                throw MalformedFixture(what: "segment \(segment)")
            }
        }
        return bytes
    }

    /// Line specs: {"range": [a, b]} | {"base": i, "replace"?: [find, replacement], "crlf"?: true,
    /// "noNewline"?: true} | {"segments": [...]}.
    private static func assemble(_ lines: [JSONValue], base: [[UInt8]]) throws -> [UInt8] {
        var bytes: [UInt8] = []
        for spec in lines {
            if let range = spec["range"]?.arrayValue {
                let start = try required(range.first?.intValue, "range start")
                let end = try required(range.last?.intValue, "range end")
                for line in base[start..<end] { bytes.append(contentsOf: line) }
            } else if let index = spec["base"]?.intValue {
                var line = Data(base[index])
                if let replacement = spec["replace"]?.arrayValue {
                    let find = Data(try required(replacement.first?.stringValue, "replace target").utf8)
                    let with = Data(try required(replacement.last?.stringValue, "replacement").utf8)
                    line.replaceSubrange(try required(line.range(of: find), "replace target in base line \(index)"), with: with)
                }
                if spec["crlf"] == .bool(true) { line.insert(0x0D, at: line.count - 1) }
                if spec["noNewline"] == .bool(true) { line.removeLast() }
                bytes.append(contentsOf: line)
            } else if let segments = spec["segments"] {
                bytes.append(contentsOf: try expand(segments))
            } else {
                throw MalformedFixture(what: "line spec \(spec)")
            }
        }
        return bytes
    }
}

private func hex(_ digest: SHA256.Digest) -> String {
    digest.map { String(format: "%02x", $0) }.joined()
}
