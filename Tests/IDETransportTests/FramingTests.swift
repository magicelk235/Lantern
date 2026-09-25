import Foundation
import IDETransport
import Testing

@Suite struct FramingTests {
    private static let frames: [ClientFrame] = [
        .hello(Hello(clientVersion: "1.0", token: "t")),
        .request(Request(id: "7", method: PTYWrite.name, params: ["ptyId": "p1", "data": "aGVsbG8="])),
        .request(Request(id: "8", method: OmpCommand.name, params: ["command": ["type": "prompt", "message": "ünïcødé ✓"]])),
    ]

    @Test func encodeWritesBigEndianLengthThenIDECodingJSON() throws {
        let frame = try FrameCodec.encode(Self.frames[1])
        let body = frame.dropFirst(4)
        let length = frame.prefix(4).reduce(0) { $0 << 8 | Int($1) }
        #expect(length == body.count)
        #expect(try IDECoding.decoder().decode(ClientFrame.self, from: body) == Self.frames[1])
        #expect(Data(body) == (try IDECoding.encoder().encode(Self.frames[1])))
    }

    @Test func decoderReassemblesFramesSplitAtEveryByteBoundary() throws {
        // A zero-length payload is valid framing, so include one between real frames.
        var stream = Data()
        var payloads: [Data] = []
        for (index, frame) in Self.frames.enumerated() {
            let encoded = try FrameCodec.encode(frame)
            stream.append(encoded)
            payloads.append(encoded.dropFirst(4))
            if index == 0 {
                stream.append(contentsOf: [0, 0, 0, 0])
                payloads.append(Data())
            }
        }

        for split in 0 ... stream.count {
            var decoder = FrameDecoder()
            var decoded = try decoder.push(stream.prefix(split))
            decoded += try decoder.push(stream.dropFirst(split))
            #expect(decoded.map { Data($0) } == payloads, "split at byte \(split)")
        }

        var decoder = FrameDecoder()
        var decoded: [Data] = []
        for byte in stream { decoded += try decoder.push(Data([byte])) }
        #expect(decoded.map { Data($0) } == payloads)
        #expect(try decoded.enumerated().filter { !$0.element.isEmpty }.map {
            try IDECoding.decoder().decode(ClientFrame.self, from: $0.element)
        } == Self.frames)
    }

    @Test func decoderEnforcesMaxFrameBytesAtTheBoundary() throws {
        var decoder = FrameDecoder(maxFrameBytes: 16)
        let atLimit = Data([0, 0, 0, 16]) + Data(repeating: 0x20, count: 16)
        #expect(try decoder.push(atLimit) == [Data(repeating: 0x20, count: 16)])

        // Rejected from the header alone, before the body arrives.
        #expect(throws: FrameError.frameTooLarge(length: 17, max: 16)) {
            try decoder.push(Data([0, 0, 0, 17]))
        }
    }
}
