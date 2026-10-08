import Foundation

/// File paths as a shell reads them back, written the way Terminal writes a dropped file's path: every character a
/// shell could take for something else (a space, a quote, a glob or an expansion) gets a backslash, which sh, bash, zsh
/// and fish all read the same way. A line break, which a backslash would swallow, is single-quoted instead.
public enum ShellQuoting {
    /// `path` escaped for a shell: `/a b/it's (1).txt` is `/a\ b/it\'s\ \(1\).txt`.
    public static func quote(_ path: String) -> String {
        var quoted = ""
        for character in path {
            if character.isNewline {
                quoted += "'\(character)'"
            } else if character.unicodeScalars.allSatisfy(isPlain) {
                quoted.append(character)
            } else {
                quoted += "\\\(character)"
            }
        }
        return quoted
    }

    /// What dropping files on a terminal types: each path escaped and followed by a space, as in Terminal.
    public static func dropText(_ paths: [String]) -> String {
        paths.map { quote($0) + " " }.joined()
    }

    /// Characters no shell reads as anything but themselves: letters and digits (any script's), and the punctuation
    /// paths are made of that no shell expands.
    private static func isPlain(_ scalar: Unicode.Scalar) -> Bool {
        guard scalar.isASCII else { return scalar.properties.generalCategory != .control }
        switch scalar {
        case "a"..."z", "A"..."Z", "0"..."9", "/", ".", "_", "-", "+", ",", ":", "@": return true
        default: return false
        }
    }
}
