/// Strict UTF-8 validation (Unicode Table 3-7 well-formed sequences: no overlongs, surrogates,
/// or scalars above U+10FFFF), equivalent to `new TextDecoder("utf-8", { fatal: true })`.
enum UTF8Validation {
    static func isValid(_ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        guard let base = bytes.baseAddress else { return true }
        let count = bytes.count
        var i = 0
        while i < count {
            if count - i >= 8,
               UnsafeRawPointer(base + i).loadUnaligned(as: UInt64.self) & 0x8080_8080_8080_8080 == 0
            {
                i += 8
                continue
            }
            let lead = base[i]
            if lead < 0x80 {
                i += 1
                continue
            }
            @inline(__always) func isContinuation(_ b: UInt8) -> Bool { b & 0xC0 == 0x80 }
            switch lead {
            case 0xC2...0xDF:
                guard i + 1 < count, isContinuation(base[i + 1]) else { return false }
                i += 2
            case 0xE0...0xEF:
                guard i + 2 < count else { return false }
                let second = base[i + 1]
                switch lead {
                case 0xE0: guard (0xA0...0xBF).contains(second) else { return false }
                case 0xED: guard (0x80...0x9F).contains(second) else { return false }
                default: guard isContinuation(second) else { return false }
                }
                guard isContinuation(base[i + 2]) else { return false }
                i += 3
            case 0xF0...0xF4:
                guard i + 3 < count else { return false }
                let second = base[i + 1]
                switch lead {
                case 0xF0: guard (0x90...0xBF).contains(second) else { return false }
                case 0xF4: guard (0x80...0x8F).contains(second) else { return false }
                default: guard isContinuation(second) else { return false }
                }
                guard isContinuation(base[i + 2]), isContinuation(base[i + 3]) else { return false }
                i += 4
            default:
                return false
            }
        }
        return true
    }
}

/// Canonical padded base64 (RFC 4648 §4, standard alphabet), as accepted by omp's reference chunk
/// decoder: the regex `^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$` plus a
/// re-encode round trip, which additionally rejects non-zero pad bits.
enum Base64 {
    private static let invalid: UInt8 = 0xFF
    private static let table: [UInt8] = {
        var table = [UInt8](repeating: invalid, count: 256)
        for (value, char) in "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8.enumerated() {
            table[Int(char)] = UInt8(value)
        }
        return table
    }()

    /// Appends the bytes encoded by `text` to `output`. Returns false for empty or non-canonical input
    /// (after which `output`'s contents past its original count are unspecified).
    static func decodeCanonical(_ text: String, into output: inout [UInt8]) -> Bool {
        var text = text
        return text.withUTF8 { decodeCanonical($0, into: &output) }
    }

    private static func decodeCanonical(_ input: UnsafeBufferPointer<UInt8>, into output: inout [UInt8]) -> Bool {
        let count = input.count
        guard count > 0, count % 4 == 0 else { return false }
        let padding = input[count - 1] != 0x3D ? 0 : input[count - 2] != 0x3D ? 1 : 2
        let fullGroups = count / 4 - (padding == 0 ? 0 : 1)
        output.reserveCapacity(output.count + count / 4 * 3)
        return table.withUnsafeBufferPointer { table in
            var i = 0
            for _ in 0..<fullGroups {
                let a = table[Int(input[i])], b = table[Int(input[i + 1])]
                let c = table[Int(input[i + 2])], d = table[Int(input[i + 3])]
                guard (a | b | c | d) & 0xC0 == 0 else { return false }
                output.append(a << 2 | b >> 4)
                output.append(b << 4 | c >> 2)
                output.append(c << 6 | d)
                i += 4
            }
            switch padding {
            case 1: // xxx=
                let a = table[Int(input[i])], b = table[Int(input[i + 1])], c = table[Int(input[i + 2])]
                guard (a | b | c) & 0xC0 == 0, c & 0x03 == 0 else { return false }
                output.append(a << 2 | b >> 4)
                output.append(b << 4 | c >> 2)
            case 2: // xx==
                let a = table[Int(input[i])], b = table[Int(input[i + 1])]
                guard (a | b) & 0xC0 == 0, b & 0x0F == 0 else { return false }
                output.append(a << 2 | b >> 4)
            default:
                break
            }
            return true
        }
    }
}
