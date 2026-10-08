import Foundation

/// Names for the copies the Files pane makes, the way Finder makes them: Duplicate's "name copy.ext", "name copy 2.ext",
/// and Keep Both's "name 2.ext" when an item of that name is already where a copy or move goes.
public enum FinderNaming {
    public enum Style: Sendable {
        /// Duplicate, or a copy pasted into its own folder: "name copy.ext", then "name copy 2.ext".
        case duplicate
        /// An item of the same name is already there: "name 2.ext", then "name 3.ext".
        case keepBoth
    }

    /// The first name for a copy of `name` that `isTaken` says is free. A folder's name keeps its dots whole; a file's
    /// extension stays at the end. A name that already ends in Finder's suffix counts on from it: a duplicate of
    /// "a copy.txt" is "a copy 2.txt", not "a copy copy.txt".
    public static func name(for name: String, isDirectory: Bool, style: Style, isTaken: (String) -> Bool) -> String {
        let (base, suffix) = split(name, isDirectory: isDirectory)
        switch style {
        case .duplicate:
            let (stem, number) = trailingNumber(of: base, after: " copy")
            var counter = number.map { $0 + 1 } ?? 1
            while true {
                let candidate = stem + (counter == 1 ? " copy" : " copy \(counter)") + suffix
                if !isTaken(candidate) { return candidate }
                counter += 1
            }
        case .keepBoth:
            let (stem, number) = trailingNumber(of: base, after: "")
            var counter = max(2, number.map { $0 + 1 } ?? 2)
            while true {
                let candidate = "\(stem) \(counter)\(suffix)"
                if !isTaken(candidate) { return candidate }
                counter += 1
            }
        }
    }

    /// The name before its extension, and the extension with its dot. A folder, a name with nothing before its only
    /// dot (".gitignore") and one ending in a dot have no extension.
    private static func split(_ name: String, isDirectory: Bool) -> (String, String) {
        guard !isDirectory else { return (name, "") }
        let pathExtension = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        guard !pathExtension.isEmpty, !base.isEmpty else { return (name, "") }
        return (base, "." + pathExtension)
    }

    /// `base` without a trailing `marker` and the number after it: "a copy 3" with " copy" is ("a", 3), "a copy" is
    /// ("a", 1); "a 3" with "" is ("a", 3). Without that ending: (`base`, nil).
    private static func trailingNumber(of base: String, after marker: String) -> (String, Int?) {
        if let space = base.lastIndex(of: " "), let number = Int(base[base.index(after: space)...]), number >= 2,
           base[base.index(after: space)...].allSatisfy(\.isASCII) {
            let head = base[..<space]
            if marker.isEmpty {
                return head.isEmpty ? (base, nil) : (String(head), number)
            }
            if head.hasSuffix(marker), head.count > marker.count { return (String(head.dropLast(marker.count)), number) }
        }
        if !marker.isEmpty, base.hasSuffix(marker), base.count > marker.count { return (String(base.dropLast(marker.count)), 1) }
        return (base, nil)
    }
}
