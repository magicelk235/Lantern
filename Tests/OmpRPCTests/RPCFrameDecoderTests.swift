import Foundation
import OmpRPC
import Testing

/// Chunked frames must declare at least 16 bytes here, so chunk sequences stay tiny. The reassembly
/// limit keeps its default (at most 256 chunks per sequence).
private func smallDecoder() -> RPCFrameDecoder {
    RPCFrameDecoder(maxFrameBytes: 16)
}

private func bytes(_ lines: [String]) -> [UInt8] {
    Array(lines.map { $0 + "\n" }.joined().utf8)
}

@Suite("RPCFrameDecoder")
struct RPCFrameDecoderTests {
    private static let chunkedPayload = #"{"type":"response","id":"req_1","data":{"text":"é€😀 ✓ 世界 \"quoted\" \\ / tail"}}"#

    private static func mixedStream() -> (bytes: [UInt8], expected: [String]) {
        let small = [
            #"{"type":"ready","protocolVersion":1}"#,
            #"{"type":"message_update","delta":"Grüße 世界 😀 \u00e9 \"q\""}"#,
        ]
        let last = #"{"type":"session_settled"}"#
        let lines = small + chunkLines(Array(chunkedPayload.utf8), chunkSize: 7) + [last]
        return (bytes(lines), small + [chunkedPayload, last])
    }

    @Test func framesSurviveEveryByteBoundary() throws {
        let (stream, expectedText) = Self.mixedStream()
        let expected = try expectedText.map(foundationJSON)

        let whole = decodeStream(stream, decoder: smallDecoder())
        #expect(whole.error == nil)
        #expect(whole.frames == expected)

        let byteByByte = decodeStream(stream, decoder: smallDecoder(), pieceSizes: [1])
        #expect(byteByByte.error == nil)
        #expect(byteByByte.frames == expected)

        for split in 1..<stream.count {
            let pieces = decodeStream(stream, decoder: smallDecoder(), pieceSizes: [split, stream.count])
            #expect(pieces.error == nil, "split at \(split)")
            #expect(pieces.frames == expected, "split at \(split)")
        }

        var random = SeededGenerator(seed: 7)
        let sizes = (0..<64).map { _ in Int.random(in: 1...40, using: &random) }
        let shuffled = decodeStream(stream, decoder: smallDecoder(), pieceSizes: sizes)
        #expect(shuffled.error == nil)
        #expect(shuffled.frames == expected)
    }

    @Test func crlfBlankAndWhitespaceOnlyLinesAreSkipped() throws {
        let stream = Array("\r\n{\"type\":\"a\"}\r\n\n   \t\r\n{\"type\":\"b\"}\r\n\n".utf8)
        let decoded = decodeStream(stream)
        #expect(decoded.error == nil)
        #expect(decoded.frames == [["type": "a"], ["type": "b"]])
    }

    @Test func finishDecodesAnUnterminatedFinalLine() throws {
        var decoder = RPCFrameDecoder()
        #expect(try decoder.push(Data(#"{"type":"a"}"#.utf8)).isEmpty)
        #expect(try decoder.finish() == [["type": "a"]])
    }

    @Test func finishRejectsATruncatedFinalLine() throws {
        var decoder = RPCFrameDecoder()
        #expect(try decoder.push(Data("{\"type\":\"a\"}\n{\"type\":\"b\",\"s\":\"cut".utf8)) == [["type": "a"]])
        #expect(throws: OmpRPCError.self) { try decoder.finish() }
    }

    @Test func linesLongerThanMaxFrameBytesAreAccepted() throws {
        let text = String(repeating: "v1 fallback ", count: 1000)
        var decoder = RPCFrameDecoder(maxFrameBytes: 64, maxReassembledBytes: 1 << 20)
        let frames = try decoder.push(Data("{\"type\":\"agent_end\",\"text\":\"\(text)\"}\n".utf8))
        #expect(frames == [["type": "agent_end", "text": .string(text)]])
    }

    @Test(arguments: [2, 3, 4, 5, 6, 7, 11])
    func reassemblesUTF8SplitAcrossChunks(chunkSize: Int) throws {
        let payload = #"{"type":"response","text":"é€😀é€😀aé€😀aaé€😀aaa"}"#
        let lines = chunkLines(Array(payload.utf8), chunkSize: chunkSize)
        var decoder = smallDecoder()
        for (index, line) in lines.enumerated() {
            let frames = try decoder.push(Data((line + "\n").utf8))
            if index < lines.count - 1 {
                #expect(frames.isEmpty)
                #expect(decoder.isReassembling)
            } else {
                #expect(frames == [try foundationJSON(payload)])
                #expect(!decoder.isReassembling)
            }
        }
    }

    struct Violation: Sendable, CustomTestStringConvertible {
        let name: String
        let lines: [String]
        /// The exact `protocolViolation` message (chunk rules mirror omp's reference decoder), or nil for any violation.
        let message: String?
        var testDescription: String { name }
    }

    /// 36 bytes, sent as four chunks of 10.
    private static let payload = Array(#"{"type":"response","n":12345678901}"#.utf8)
    private static let good = chunkLines(payload, chunkSize: 10)
    private static func line(index: Int, count: Int = 4, byteLength: Int = payload.count, chunkId: String = "rpc-1") -> String {
        let slice = payload[(index * 10)..<min(payload.count, index * 10 + 10)]
        return chunkLine(chunkId: chunkId, index: index, count: count, byteLength: byteLength, data: Data(slice).base64EncodedString())
    }
    private static func sequence(byteLength: Int) -> [String] {
        (0..<4).map { line(index: $0, byteLength: byteLength) }
    }

    static let violations: [Violation] = [
        Violation(name: "wrong chunkId", lines: [good[0], line(index: 1, chunkId: "rpc-2")], message: "rpc chunk sequence mismatch"),
        Violation(name: "index gap", lines: [good[0], good[2]], message: "rpc chunk sequence mismatch"),
        Violation(name: "repeated index", lines: [good[0], good[1], good[1]], message: "rpc chunk sequence mismatch"),
        Violation(name: "count mismatch", lines: [good[0], line(index: 1, count: 3)], message: "rpc chunk sequence mismatch"),
        Violation(name: "byteLength mismatch between chunks", lines: [good[0], line(index: 1, byteLength: 37)], message: "rpc chunk sequence mismatch"),
        Violation(name: "declared byteLength above the data", lines: sequence(byteLength: 37), message: "rpc chunk sequence length mismatch"),
        Violation(name: "data beyond the declared byteLength", lines: sequence(byteLength: 25), message: "rpc chunk sequence exceeds declared length"),
        Violation(name: "sequence not starting at index 0", lines: [good[1]], message: "rpc chunk sequence must start at index 0"),
        Violation(name: "interleaved frame", lines: [good[0], #"{"type":"agent_start"}"#, good[1]], message: "rpc chunk sequence interrupted"),
        Violation(name: "interleaved non-object", lines: [good[0], "[1,2]"], message: "rpc chunk sequence interrupted"),
        Violation(name: "stream ends mid-sequence", lines: [good[0], good[1]], message: "rpc chunk sequence interrupted"),
        Violation(name: "byteLength above the reassembly limit", lines: [line(index: 0, byteLength: (64 << 20) + 1)], message: "invalid rpc chunk metadata"),
        Violation(name: "byteLength below maxFrameBytes", lines: [line(index: 0, byteLength: 15)], message: "invalid rpc chunk metadata"),
        Violation(name: "count above the reassembly limit", lines: [line(index: 0, count: 257)], message: "invalid rpc chunk metadata"),
        Violation(name: "count below two", lines: [line(index: 0, count: 1)], message: "invalid rpc chunk metadata"),
        Violation(name: "index not below count", lines: [line(index: 0, count: 4).replacingOccurrences(of: #""index":0"#, with: #""index":4"#)], message: "invalid rpc chunk metadata"),
        Violation(name: "fractional index", lines: [line(index: 0).replacingOccurrences(of: #""index":0"#, with: #""index":0.5"#)], message: "invalid rpc chunk metadata"),
        Violation(name: "empty chunkId", lines: [line(index: 0, chunkId: "")], message: "invalid rpc chunk metadata"),
        Violation(name: "chunkId over 128 UTF-16 units", lines: [line(index: 0, chunkId: String(repeating: "😀", count: 65))], message: "invalid rpc chunk metadata"),
        Violation(name: "data outside the base64 alphabet", lines: [chunkLine(chunkId: "c", index: 0, count: 4, byteLength: 36, data: "ab!d")], message: "invalid rpc chunk data"),
        Violation(name: "non-canonical pad bits", lines: [chunkLine(chunkId: "c", index: 0, count: 4, byteLength: 36, data: "QR==")], message: "invalid rpc chunk data"),
        Violation(name: "missing padding", lines: [chunkLine(chunkId: "c", index: 0, count: 4, byteLength: 36, data: "QQ")], message: "invalid rpc chunk data"),
        Violation(name: "empty data", lines: [chunkLine(chunkId: "c", index: 0, count: 4, byteLength: 36, data: "")], message: "invalid rpc chunk data"),
        Violation(
            name: "chunk payload above 256 KiB",
            lines: [chunkLine(chunkId: "c", index: 0, count: 4, byteLength: 1 << 20, data: Data(count: (256 << 10) + 1).base64EncodedString())],
            message: "rpc chunk payload exceeds the transport limit"
        ),
        Violation(name: "reassembled bytes not UTF-8", lines: chunkLines(Array(#"{"type":"x","s":""#.utf8) + [0xFF] + Array(#""}"#.utf8), chunkSize: 10), message: "reassembled rpc frame is not valid UTF-8"),
        Violation(name: "reassembled overlong UTF-8", lines: chunkLines(Array(#"{"type":"x","s":""#.utf8) + [0xC0, 0xAF] + Array(#""}"#.utf8), chunkSize: 10), message: "reassembled rpc frame is not valid UTF-8"),
        Violation(name: "reassembled bytes not JSON", lines: chunkLines(Array(#"{"type":"x","s":"unterminated}"#.utf8), chunkSize: 10), message: nil),
        Violation(name: "reassembled value not an object", lines: chunkLines(Array(#"["response","not","an","object"]"#.utf8), chunkSize: 10), message: "rpc frame must be an object"),
        Violation(name: "line holding a number", lines: ["42"], message: "rpc frame must be an object"),
        Violation(name: "line holding an array", lines: [#"[{"type":"a"}]"#], message: "rpc frame must be an object"),
        Violation(name: "malformed JSON line", lines: ["{nope}"], message: nil),
        Violation(name: "two values on one line", lines: [#"{"type":"a"} {"type":"b"}"#], message: nil),
        Violation(name: "raw control character in a string", lines: ["{\"type\":\"a\",\"s\":\"\u{1}\"}"], message: nil),
    ]

    @Test(arguments: violations)
    func rejects(_ violation: Violation) {
        let (_, error) = decodeStream(bytes(violation.lines), decoder: smallDecoder())
        guard case .protocolViolation(let message)? = error else {
            Issue.record("expected a protocol violation, got \(String(describing: error))")
            return
        }
        if let expected = violation.message {
            #expect(message == expected)
        }
    }

    @Test func framesBeforeAViolationAreEmittedAndTheErrorSticks() throws {
        var decoder = RPCFrameDecoder()
        var frames: [JSONValue] = []
        let input = Array("{\"type\":\"a\"}\n{\"type\":\"b\"}\n{nope}\n{\"type\":\"c\"}\n".utf8)
        var first: OmpRPCError?
        do {
            try input.withUnsafeBytes { try decoder.push($0) { frames.append($0) } }
        } catch let error as OmpRPCError {
            first = error
        }
        #expect(frames == [["type": "a"], ["type": "b"]])
        #expect(first != nil)
        // The rest of the stream is out of sync; the decoder keeps reporting the original failure.
        #expect(throws: first!) { try decoder.push(Data("{\"type\":\"d\"}\n".utf8)) }
        #expect(throws: first!) { try decoder.finish() }
    }

    @Test func deepNestingIsRejectedWithoutExhaustingTheStack() {
        let depth = 100_000
        let line = #"{"type":"deep","v":"# + String(repeating: "[", count: depth) + String(repeating: "]", count: depth) + "}\n"
        let (frames, error) = decodeStream(Array(line.utf8))
        #expect(frames.isEmpty)
        #expect(error != nil)
    }

    @Test func loneSurrogateEscapesBecomeReplacementCharacters() throws {
        var decoder = RPCFrameDecoder()
        let frames = try decoder.push(Data(#"{"type":"s","a":"x\ud800y","b":"\udc00","c":"\ud83d\ude00","d":"\ud83d\u0041"}"#.utf8 + [0x0A]))
        #expect(frames == [["type": "s", "a": "x\u{FFFD}y", "b": "\u{FFFD}", "c": "😀", "d": "\u{FFFD}A"]])
    }

    @Test func agreesWithFoundationOnRandomDocuments() throws {
        var random = SeededGenerator(seed: 0x0DDB_A11)
        let encoder = JSONEncoder()
        for _ in 0..<400 {
            let document: JSONValue = ["type": "random", "value": randomValue(depth: 0, using: &random)]
            let data = try encoder.encode(document)
            var decoder = RPCFrameDecoder()
            let frames = try decoder.push(data + [0x0A])
            #expect(frames == [try JSONDecoder().decode(JSONValue.self, from: data)])
        }
    }
}

private func randomValue(depth: Int, using random: inout SeededGenerator) -> JSONValue {
    let pick = Int.random(in: 0..<(depth > 4 ? 5 : 8), using: &random)
    switch pick {
    case 0: return .null
    case 1: return .bool(Bool.random(using: &random))
    case 2: return .number(Double(Int.random(in: -1_000_000...1_000_000, using: &random)))
    case 3: return .number(Double.random(in: -1e12...1e12, using: &random) * pow(10, Double(Int.random(in: -30...30, using: &random))))
    case 4: return .string(randomString(using: &random))
    case 5, 6:
        return .array((0..<Int.random(in: 0...5, using: &random)).map { _ in randomValue(depth: depth + 1, using: &random) })
    default:
        var object: [String: JSONValue] = [:]
        for _ in 0..<Int.random(in: 0...5, using: &random) {
            object[randomString(using: &random)] = randomValue(depth: depth + 1, using: &random)
        }
        return .object(object)
    }
}

private func randomString(using random: inout SeededGenerator) -> String {
    let alphabet: [Character] = ["a", "Z", "0", " ", "\"", "\\", "/", "\n", "\t", "\u{1}", "\u{1F}", "\u{7F}", "é", "€", "世", "😀", "\u{2028}", "\u{FFFF}", "e\u{301}"]
    return String((0..<Int.random(in: 0...12, using: &random)).map { _ in alphabet.randomElement(using: &random)! })
}

@Suite("JSONValue")
struct JSONValueTests {
    @Test func intValueIsNilForNumbersOutsideIntInsteadOfTrapping() {
        #expect(JSONValue.number(-3.7).intValue == -3)
        #expect(JSONValue.number(.infinity).intValue == nil)
        #expect(JSONValue.number(.nan).intValue == nil)
        #expect(JSONValue.number(1e300).intValue == nil)
        #expect(JSONValue.number(-9_223_372_036_854_775_808).intValue == Int.min)
    }
}
