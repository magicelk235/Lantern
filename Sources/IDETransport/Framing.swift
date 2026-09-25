import Foundation
@_exported import IDEProtocol

/// Framing failures. After a `FrameDecoder` throws, the stream is unrecoverable; discard the decoder and close.
public enum FrameError: Error, Sendable, Equatable {
    /// A frame's declared (or encoded) length exceeds the allowed maximum.
    case frameTooLarge(length: Int, max: Int)
}

/// Wire frames: a 4-byte big-endian payload length followed by the payload, one JSON document
/// encoded with `IDECoding.encoder()`.
public enum FrameCodec {
    /// Encodes `value` as one complete frame (header + JSON). Throws `FrameError.frameTooLarge` above `ideMaxFrameBytes`.
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let json = try Coders.encoder.encode(value)
        guard json.count <= ideMaxFrameBytes else { throw FrameError.frameTooLarge(length: json.count, max: ideMaxFrameBytes) }
        var frame = Data(capacity: 4 + json.count)
        withUnsafeBytes(of: UInt32(json.count).bigEndian) { frame.append(contentsOf: $0) }
        frame.append(json)
        return frame
    }
}

/// Incremental frame splitter for a byte stream that may arrive in arbitrary chunks.
///
/// Returned payloads are exactly the frame bodies (no header). They may be slices of the pushed or buffered bytes,
/// so index them from `startIndex`, not 0.
public struct FrameDecoder: Sendable {
    public let maxFrameBytes: Int
    /// Bytes of an incomplete frame carried over to the next `push`. Always compact (starts at index 0).
    private var pending = Data()

    public init(maxFrameBytes: Int = ideMaxFrameBytes) {
        self.maxFrameBytes = maxFrameBytes
    }

    /// Feeds the next chunk of the stream; returns every frame payload it completes, in stream order.
    public mutating func push(_ data: Data) throws -> [Data] {
        guard !data.isEmpty else { return [] }
        var frames: [Data] = []
        if pending.isEmpty {
            // Fast path: split straight out of the incoming chunk; only an incomplete tail is copied.
            let consumed = try Self.split(data, maxFrameBytes: maxFrameBytes, into: &frames)
            if consumed < data.count { pending = Data(data[(data.startIndex + consumed)...]) }
        } else {
            pending.append(data)
            let consumed = try Self.split(pending, maxFrameBytes: maxFrameBytes, into: &frames)
            if consumed == pending.count {
                pending = Data()
            } else if consumed > 0 {
                // Returned frames keep the old buffer alive; the carried-over tail gets fresh, compact storage.
                pending = Data(pending[(pending.startIndex + consumed)...])
            }
        }
        return frames
    }

    /// Appends each complete frame payload in `bytes` to `frames`; returns how many bytes were consumed.
    private static func split(_ bytes: Data, maxFrameBytes: Int, into frames: inout [Data]) throws -> Int {
        var offset = bytes.startIndex
        let end = bytes.endIndex
        while end - offset >= 4 {
            let length = Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            guard length <= maxFrameBytes else { throw FrameError.frameTooLarge(length: length, max: maxFrameBytes) }
            let body = offset + 4
            guard end - body >= length else { break }
            frames.append(bytes[body ..< body + length])
            offset = body + length
        }
        return offset - bytes.startIndex
    }
}

/// Shared `IDECoding` coders. JSONEncoder/JSONDecoder are thread-safe (`@unchecked Sendable` in Foundation) and these
/// instances are never reconfigured.
enum Coders {
    static let encoder = IDECoding.encoder()
    static let decoder = IDECoding.decoder()
}

/// Typed value <-> `JSONValue` conversion for request params and results. Goes through the `IDECoding` coders (not
/// `JSONValue(encoding:)`) so dates keep the wire's ISO-8601 representation.
enum WireJSON {
    static func value<T: Encodable>(_ value: T) throws -> JSONValue {
        if let json = value as? JSONValue { return json }
        return try Coders.decoder.decode(JSONValue.self, from: Coders.encoder.encode(value))
    }

    static func decode<T: Decodable>(_ type: T.Type, from json: JSONValue) throws -> T {
        if let value = json as? T { return value }
        return try Coders.decoder.decode(T.self, from: Coders.encoder.encode(json))
    }
}
