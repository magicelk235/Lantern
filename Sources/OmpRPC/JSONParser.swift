import Foundation

/// Why `JSONParser` rejected its input.
struct JSONParseError: Error, Sendable {
    /// Byte offset of the offending input.
    let offset: Int
    let reason: String
}

/// RFC 8259 parser that builds `JSONValue` trees straight from UTF-8 bytes, matching `JSON.parse`
/// as used by omp's reference client:
/// - whitespace is space, tab, LF and CR only, and the input holds exactly one value;
/// - duplicate object keys keep the last value;
/// - invalid UTF-8 inside strings becomes U+FFFD (maximal-subpart substitution, like Bun's JSONL
///   reader); callers that need strict UTF-8 validate first (`UTF8Validation.isValid`);
/// - lone UTF-16 surrogate escapes (`"\ud800"`) become U+FFFD because Swift strings cannot hold them.
///
/// Parsing is iterative, so nesting never consumes native stack here. Containers may still nest at
/// most `maxDepth` levels: `JSONValue`'s deinit, `Codable` and `Hashable` conformances all recurse,
/// and an unbounded tree from hostile input would overflow a 512 KiB dispatch-thread stack later.
struct JSONParser {
    static let defaultMaxDepth = 512

    private let bytes: UnsafeBufferPointer<UInt8>
    private let maxDepth: Int
    private var i = 0
    private var scratch: [UInt8] = []

    private init(bytes: UnsafeBufferPointer<UInt8>, maxDepth: Int) {
        self.bytes = bytes
        self.maxDepth = maxDepth
    }

    static func parse(_ input: UnsafeRawBufferPointer, maxDepth: Int = defaultMaxDepth) throws(JSONParseError) -> JSONValue {
        var parser = JSONParser(bytes: input.assumingMemoryBound(to: UInt8.self), maxDepth: maxDepth)
        parser.skipWhitespace()
        let value = try parser.parseValue()
        parser.skipWhitespace()
        guard parser.i == parser.bytes.count else { throw parser.failure("unexpected data after the JSON value") }
        return value
    }

    private func failure(_ reason: String) -> JSONParseError {
        JSONParseError(offset: i, reason: reason)
    }

    private mutating func skipWhitespace() {
        while i < bytes.count {
            switch bytes[i] {
            case 0x20, 0x09, 0x0A, 0x0D: i += 1
            default: return
            }
        }
    }

    private enum Container { case array, object }

    /// Parses one value starting at `i` (whitespace already skipped).
    private mutating func parseValue() throws(JSONParseError) -> JSONValue {
        var open: [Container] = []
        var arrays: [[JSONValue]] = []
        var objects: [[String: JSONValue]] = []
        var keys: [String] = []

        values: while true {
            guard i < bytes.count else { throw failure("unexpected end of input") }
            var value: JSONValue
            switch bytes[i] {
            case 0x7B: // {
                i += 1
                skipWhitespace()
                if i < bytes.count, bytes[i] == 0x7D {
                    i += 1
                    value = .object([:])
                } else {
                    guard open.count < maxDepth else { throw failure("containers nest deeper than \(maxDepth) levels") }
                    keys.append(try parseKey())
                    open.append(.object)
                    objects.append([:])
                    continue values
                }
            case 0x5B: // [
                i += 1
                skipWhitespace()
                if i < bytes.count, bytes[i] == 0x5D {
                    i += 1
                    value = .array([])
                } else {
                    guard open.count < maxDepth else { throw failure("containers nest deeper than \(maxDepth) levels") }
                    open.append(.array)
                    arrays.append([])
                    continue values
                }
            case 0x22: value = .string(try parseString())
            case 0x74: try expectLiteral("true"); value = .bool(true)
            case 0x66: try expectLiteral("false"); value = .bool(false)
            case 0x6E: try expectLiteral("null"); value = .null
            case 0x2D, 0x30...0x39: value = .number(try parseNumber())
            default: throw failure("unexpected character")
            }

            // Attach the finished value to its container, closing containers as their ends arrive.
            while let container = open.last {
                skipWhitespace()
                guard i < bytes.count else { throw failure("unexpected end of input") }
                let c = bytes[i]
                switch container {
                case .array:
                    arrays[arrays.count - 1].append(value)
                    if c == 0x2C { // ,
                        i += 1
                        skipWhitespace()
                        continue values
                    }
                    guard c == 0x5D else { throw failure("expected ',' or ']'") }
                    i += 1
                    open.removeLast()
                    value = .array(arrays.removeLast())
                case .object:
                    objects[objects.count - 1][keys.removeLast()] = value
                    if c == 0x2C { // ,
                        i += 1
                        skipWhitespace()
                        keys.append(try parseKey())
                        continue values
                    }
                    guard c == 0x7D else { throw failure("expected ',' or '}'") }
                    i += 1
                    open.removeLast()
                    value = .object(objects.removeLast())
                }
            }
            return value
        }
    }

    /// Parses `"key"` and the following `:`, leaving `i` at the value.
    private mutating func parseKey() throws(JSONParseError) -> String {
        guard i < bytes.count, bytes[i] == 0x22 else { throw failure("expected a string key") }
        let key = try parseString()
        skipWhitespace()
        guard i < bytes.count, bytes[i] == 0x3A else { throw failure("expected ':'") }
        i += 1
        skipWhitespace()
        return key
    }

    private mutating func expectLiteral(_ literal: StaticString) throws(JSONParseError) {
        let count = literal.utf8CodeUnitCount
        guard bytes.count - i >= count else { throw failure("invalid literal") }
        let expected = literal.utf8Start
        for k in 0..<count where bytes[i + k] != expected[k] {
            throw failure("invalid literal")
        }
        i += count
    }

    /// Parses a string starting at its opening quote.
    private mutating func parseString() throws(JSONParseError) -> String {
        i += 1
        let start = i
        while i < bytes.count {
            let c = bytes[i]
            if c == 0x22 {
                let text = String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<i]), as: UTF8.self)
                i += 1
                return text
            }
            if c == 0x5C { return try parseEscapedString(from: start) }
            if c < 0x20 { throw failure("unescaped control character in string") }
            i += 1
        }
        throw failure("unterminated string")
    }

    /// Slow path once a backslash shows up: accumulates the decoded UTF-8 in `scratch`.
    private mutating func parseEscapedString(from start: Int) throws(JSONParseError) -> String {
        scratch.removeAll(keepingCapacity: true)
        scratch.append(contentsOf: UnsafeBufferPointer(rebasing: bytes[start..<i]))
        while i < bytes.count {
            let c = bytes[i]
            if c == 0x22 {
                i += 1
                return String(decoding: scratch, as: UTF8.self)
            }
            if c == 0x5C {
                i += 1
                guard i < bytes.count else { throw failure("unterminated escape") }
                let escape = bytes[i]
                i += 1
                switch escape {
                case 0x22, 0x5C, 0x2F: scratch.append(escape)
                case 0x62: scratch.append(0x08)
                case 0x66: scratch.append(0x0C)
                case 0x6E: scratch.append(0x0A)
                case 0x72: scratch.append(0x0D)
                case 0x74: scratch.append(0x09)
                case 0x75: appendScalar(try parseUnicodeEscape())
                default: throw failure("invalid escape")
                }
                continue
            }
            if c < 0x20 { throw failure("unescaped control character in string") }
            var end = i + 1
            while end < bytes.count {
                let b = bytes[end]
                if b == 0x22 || b == 0x5C || b < 0x20 { break }
                end += 1
            }
            scratch.append(contentsOf: UnsafeBufferPointer(rebasing: bytes[i..<end]))
            i = end
        }
        throw failure("unterminated string")
    }

    /// Decodes the `XXXX` of `\uXXXX` (and a following low-surrogate escape when it pairs).
    private mutating func parseUnicodeEscape() throws(JSONParseError) -> UInt32 {
        guard let unit = hex4(at: i) else { throw failure("invalid \\u escape") }
        i += 4
        switch unit {
        case 0xD800...0xDBFF:
            if i + 6 <= bytes.count, bytes[i] == 0x5C, bytes[i + 1] == 0x75,
               let low = hex4(at: i + 2), (0xDC00...0xDFFF).contains(low)
            {
                i += 6
                return 0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00)
            }
            return 0xFFFD
        case 0xDC00...0xDFFF:
            return 0xFFFD
        default:
            return unit
        }
    }

    private func hex4(at offset: Int) -> UInt32? {
        guard offset + 4 <= bytes.count else { return nil }
        var value: UInt32 = 0
        for k in offset..<offset + 4 {
            let b = bytes[k]
            let digit: UInt8
            switch b {
            case 0x30...0x39: digit = b - 0x30
            case 0x41...0x46: digit = b - 0x41 + 10
            case 0x61...0x66: digit = b - 0x61 + 10
            default: return nil
            }
            value = value << 4 | UInt32(digit)
        }
        return value
    }

    private mutating func appendScalar(_ scalar: UInt32) {
        switch scalar {
        case 0..<0x80:
            scratch.append(UInt8(scalar))
        case 0x80..<0x800:
            scratch.append(UInt8(0xC0 | scalar >> 6))
            scratch.append(UInt8(0x80 | scalar & 0x3F))
        case 0x800..<0x10000:
            scratch.append(UInt8(0xE0 | scalar >> 12))
            scratch.append(UInt8(0x80 | scalar >> 6 & 0x3F))
            scratch.append(UInt8(0x80 | scalar & 0x3F))
        default:
            scratch.append(UInt8(0xF0 | scalar >> 18))
            scratch.append(UInt8(0x80 | scalar >> 12 & 0x3F))
            scratch.append(UInt8(0x80 | scalar >> 6 & 0x3F))
            scratch.append(UInt8(0x80 | scalar & 0x3F))
        }
    }

    /// Parses `-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?` into the nearest `Double`.
    private mutating func parseNumber() throws(JSONParseError) -> Double {
        let start = i
        let negative = bytes[i] == 0x2D
        if negative { i += 1 }
        guard i < bytes.count else { throw failure("invalid number") }
        var mantissa: UInt64 = 0
        var digits = 0
        if bytes[i] == 0x30 {
            i += 1
            digits = 1
        } else if (0x31...0x39).contains(bytes[i]) {
            while i < bytes.count, (0x30...0x39).contains(bytes[i]) {
                if digits < 16 { mantissa = mantissa * 10 + UInt64(bytes[i] - 0x30) }
                digits += 1
                i += 1
            }
        } else {
            throw failure("invalid number")
        }
        var integral = true
        if i < bytes.count, bytes[i] == 0x2E { // .
            integral = false
            i += 1
            guard i < bytes.count, (0x30...0x39).contains(bytes[i]) else { throw failure("invalid number") }
            while i < bytes.count, (0x30...0x39).contains(bytes[i]) { i += 1 }
        }
        if i < bytes.count, bytes[i] == 0x65 || bytes[i] == 0x45 { // e E
            integral = false
            i += 1
            if i < bytes.count, bytes[i] == 0x2B || bytes[i] == 0x2D { i += 1 }
            guard i < bytes.count, (0x30...0x39).contains(bytes[i]) else { throw failure("invalid number") }
            while i < bytes.count, (0x30...0x39).contains(bytes[i]) { i += 1 }
        }
        if integral && digits <= 15 {
            // Exact: every integer below 10^15 is representable.
            let magnitude = Double(mantissa)
            return negative ? -magnitude : magnitude
        }
        // Correctly rounded conversion of the literal (strtod semantics; overflow gives ±infinity).
        let literal = String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<i]), as: UTF8.self)
        guard let value = Double(literal) else { throw failure("invalid number") }
        return value
    }
}
