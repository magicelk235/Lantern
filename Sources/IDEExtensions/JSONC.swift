import Foundation

/// JSON as VS Code reads its own files (package.json, themes, snippets, language configurations): `//` and `/* */`
/// comments and a comma before a closing bracket are allowed, and a control character typed into a string (a tab in a
/// snippet body) is kept as written.
public enum JSONC {
    /// The value `data` holds, as `JSONSerialization` gives it: dictionaries, arrays, strings and numbers.
    public static func object(from data: Data) throws -> Any {
        try JSONSerialization.jsonObject(with: strict(data), options: [.fragmentsAllowed])
    }

    /// `data` as strict JSON: without a byte order mark, comments or trailing commas, and with the control characters
    /// in strings escaped. A comment becomes a space, so it still separates what it stood between (`1/**/2` is two
    /// numbers, not `12`).
    private static func strict(_ data: Data) -> Data {
        var input = [UInt8](data)
        if input.starts(with: [0xEF, 0xBB, 0xBF]) { input.removeFirst(3) }
        var output: [UInt8] = []
        output.reserveCapacity(input.count)
        var index = 0
        var inString = false
        while index < input.count {
            let byte = input[index]
            let next = index + 1 < input.count ? input[index + 1] : nil
            if inString {
                switch byte {
                case UInt8(ascii: "\\"):
                    output.append(byte)
                    if let next {
                        output.append(next)
                        index += 1
                    }
                case UInt8(ascii: "\""):
                    output.append(byte)
                    inString = false
                case 0..<0x20:
                    output.append(contentsOf: escaped(byte))
                default:
                    output.append(byte)
                }
                index += 1
                continue
            }
            switch byte {
            case UInt8(ascii: "\""):
                inString = true
                output.append(byte)
                index += 1
            case UInt8(ascii: "/") where next == UInt8(ascii: "/"):
                while index < input.count, input[index] != UInt8(ascii: "\n"), input[index] != UInt8(ascii: "\r") {
                    index += 1
                }
            case UInt8(ascii: "/") where next == UInt8(ascii: "*"):
                index += 2
                while index < input.count, !(input[index] == UInt8(ascii: "*") && index + 1 < input.count
                    && input[index + 1] == UInt8(ascii: "/")) {
                    index += 1
                }
                index = min(index + 2, input.count)
                output.append(UInt8(ascii: " "))
            case UInt8(ascii: "]"), UInt8(ascii: "}"):
                if let last = output.lastIndex(where: { !isWhitespace($0) }), output[last] == UInt8(ascii: ",") {
                    output[last] = UInt8(ascii: " ")
                }
                output.append(byte)
                index += 1
            default:
                output.append(byte)
                index += 1
            }
        }
        return Data(output)
    }

    private static func escaped(_ byte: UInt8) -> [UInt8] {
        switch byte {
        case UInt8(ascii: "\t"): Array(#"\t"#.utf8)
        case UInt8(ascii: "\n"): Array(#"\n"#.utf8)
        case UInt8(ascii: "\r"): Array(#"\r"#.utf8)
        default: Array(String(format: "\\u%04x", UInt32(byte)).utf8)
        }
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        [UInt8(ascii: " "), UInt8(ascii: "\t"), UInt8(ascii: "\n"), UInt8(ascii: "\r")].contains(byte)
    }
}
