import Darwin
import Foundation

/// omp's names for what it keeps per project folder (omp 18: `session-paths.ts`, `mnemopi/config.ts`, `dirs.ts`):
/// the folder of its session files, the memory bank, the record of a session file kept outside its session store. Both
/// sides need them: Lantern lists a project's session files, ompd moves them when the project's folder is renamed.
public enum OmpPaths {
    /// omp's folder under `<agent dir>/sessions` for a cwd (`encodeSessionDirName`): `-tmp-<relative>` under the
    /// temporary folder, else `-<relative>` under the home folder, else `--<absolute>--`; `/`, `\` and `:` in the path
    /// become `-`. All three paths are canonical (`realpath`).
    public static func sessionDirectoryName(canonicalCwd cwd: String, home: String, temporaryDirectory: String) -> String {
        if let relative = relativePath(of: cwd, inside: temporaryDirectory) {
            return joined("-tmp", relative)
        }
        if let relative = relativePath(of: cwd, inside: home) {
            return joined("-", relative)
        }
        return "--\(dashed(String(cwd.drop { $0 == "/" || $0 == "\\" })))--"
    }

    /// The cwd as omp itself names it (`getProjectDir`): a canonical `/private/tmp/x` is `/tmp/x` when both name the same
    /// folder. omp writes this form into session headers, its prompt history and memory, and hashes it into the bank's
    /// name; it buckets session files by the canonical form.
    public static func ompCwd(_ canonical: String) -> String {
        let prefix = "/private/"
        guard canonical.hasPrefix(prefix) else { return canonical }
        let stripped = String(canonical.dropFirst(prefix.count - 1))
        guard let real = resolved(canonical), let strippedReal = resolved(stripped), real == strippedReal else { return canonical }
        return stripped
    }

    /// The Mnemopi bank of a cwd in omp's form, per project (`mnemopi.scoping` `per-project` or `per-project-tagged`):
    /// `<folder name>-<base36 hash of the cwd>`, after `<base>-` when `mnemopi.bank` names a base; at most 64 characters.
    public static func memoryBank(cwd: String, base: String?) -> String {
        let name = bankName(lastComponent(of: cwd)) ?? "default"
        let project = clipped("\(name)-\(String(bunHash(cwd), radix: 36))")
        guard let base = bankName(base) else { return project }
        return clipped("\(base)-\(project)")
    }

    /// The name of omp's record (`<agent dir>/custom-session-files/<name>`, whose content is the path) of a session file
    /// kept outside its session store: the last 7 hex digits of the path's hash.
    public static func customSessionRecordName(sessionFile: String) -> String {
        let hex = String(bunHash(sessionFile), radix: 16)
        return String((String(repeating: "0", count: max(0, 16 - hex.count)) + hex).suffix(7))
    }

    /// `Bun.hash` of a string: Wyhash (Zig's final v4.2, seed 0) of its UTF-8.
    public static func bunHash(_ string: String) -> UInt64 {
        Wyhash.hash(Array(string.utf8))
    }

    // MARK: - Helpers

    /// Node's `path.relative(base, path)` when it neither climbs out (`..`) nor is absolute; nil otherwise.
    private static func relativePath(of path: String, inside base: String) -> String? {
        let relative: String
        if path == base {
            relative = ""
        } else if base == "/" {
            relative = String(path.dropFirst())
        } else if path.hasPrefix(base + "/") {
            relative = String(path.dropFirst(base.count + 1))
        } else {
            return nil
        }
        return relative.hasPrefix("..") ? nil : relative
    }

    private static func joined(_ prefix: String, _ relative: String) -> String {
        let tail = dashed(relative)
        guard !tail.isEmpty else { return prefix }
        return prefix.hasSuffix("-") ? prefix + tail : "\(prefix)-\(tail)"
    }

    private static func dashed(_ path: String) -> String {
        String(path.map { $0 == "/" || $0 == "\\" || $0 == ":" ? "-" : $0 })
    }

    /// Node's `path.basename`: "" for the root.
    private static func lastComponent(of path: String) -> String {
        var path = Substring(path)
        while path.count > 1, path.hasSuffix("/") { path = path.dropLast() }
        guard let slash = path.lastIndex(of: "/") else { return String(path) }
        return String(path[path.index(after: slash)...])
    }

    /// A bank name part: runs of anything but ASCII letters, digits, `_` and `-` made `-`, `-` trimmed at both ends;
    /// nil when nothing is left.
    private static func bankName(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        var sanitized = ""
        var inRun = false
        for scalar in text.unicodeScalars {
            let kept = scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "-")
            if kept {
                sanitized.unicodeScalars.append(scalar)
                inRun = false
            } else if !inRun {
                sanitized.append("-")
                inRun = true
            }
        }
        let trimmed = sanitized.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? nil : clipped(trimmed)
    }

    /// At most 64 characters: a longer name keeps its start and ends in its own hash.
    private static func clipped(_ name: String) -> String {
        guard name.count > 64 else { return name }
        let hash = String(bunHash(name), radix: 36)
        let start = String(name.prefix(max(1, 63 - hash.count))).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return "\(start.isEmpty ? "bank" : start)-\(hash)"
    }

    private static func resolved(_ path: String) -> String? {
        guard let real = realpath(path, nil) else { return nil }
        defer { free(real) }
        return String(cString: real)
    }
}

/// Wyhash as Zig's standard library implements it (final v4.2), which Bun's `Bun.hash` is.
enum Wyhash {
    private static let secret: (UInt64, UInt64, UInt64, UInt64) =
        (0xa076_1d64_78bd_642f, 0xe703_7ed1_a0b4_28db, 0x8ebc_6af0_9c88_c6e3, 0x5899_65cc_7537_4cc3)

    static func hash(_ input: [UInt8], seed: UInt64 = 0) -> UInt64 {
        var state0 = seed ^ mix(seed ^ secret.0, secret.1)
        var state1 = state0
        var state2 = state0
        var a: UInt64 = 0
        var b: UInt64 = 0
        let count = input.count
        if count <= 16 {
            if count >= 4 {
                let end = count - 4
                let quarter = (count >> 3) << 2
                a = (read32(input, 0) << 32) | read32(input, quarter)
                b = (read32(input, end) << 32) | read32(input, end - quarter)
            } else if count > 0 {
                a = (UInt64(input[0]) << 16) | (UInt64(input[count >> 1]) << 8) | UInt64(input[count - 1])
            }
        } else {
            var index = 0
            if count >= 48 {
                while index + 48 < count {
                    state0 = mix(read64(input, index) ^ secret.1, read64(input, index + 8) ^ state0)
                    state1 = mix(read64(input, index + 16) ^ secret.2, read64(input, index + 24) ^ state1)
                    state2 = mix(read64(input, index + 32) ^ secret.3, read64(input, index + 40) ^ state2)
                    index += 48
                }
                state0 ^= state1 ^ state2
            }
            while index + 16 < count {
                state0 = mix(read64(input, index) ^ secret.1, read64(input, index + 8) ^ state0)
                index += 16
            }
            a = read64(input, count - 16)
            b = read64(input, count - 8)
        }
        a ^= secret.1
        b ^= state0
        (a, b) = multiply(a, b)
        return mix(a ^ secret.0 ^ UInt64(count), b ^ secret.1)
    }

    private static func multiply(_ a: UInt64, _ b: UInt64) -> (UInt64, UInt64) {
        let product = a.multipliedFullWidth(by: b)
        return (product.low, product.high)
    }

    private static func mix(_ a: UInt64, _ b: UInt64) -> UInt64 {
        let (low, high) = multiply(a, b)
        return low ^ high
    }

    private static func read64(_ bytes: [UInt8], _ offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for index in 0..<8 { value |= UInt64(bytes[offset + index]) << (8 * UInt64(index)) }
        return value
    }

    private static func read32(_ bytes: [UInt8], _ offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for index in 0..<4 { value |= UInt64(bytes[offset + index]) << (8 * UInt64(index)) }
        return value
    }
}
