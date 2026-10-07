import Foundation

/// The find bar's searching, apart from the text view: where an expression matches, which match Find Next and Find
/// Previous go to, and Replace All. Matches may be empty (`^`, `$`, `\b`, lookarounds): they mark a place, a line's
/// start or end, and moving on from one skips past it.
public enum TextSearch {
    /// Every match of `expression` in `text`, in order; an empty match counts.
    public static func matches(of expression: NSRegularExpression, in text: String) -> [NSRange] {
        expression.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)).map(\.range)
    }

    /// The index of the first of `matches` that starts at or after `location`; `matches.count` when none does.
    public static func firstIndex(in matches: [NSRange], atOrAfter location: Int) -> Int {
        var low = 0
        var high = matches.count
        while low < high {
            let middle = (low + high) / 2
            if matches[middle].location < location { low = middle + 1 } else { high = middle }
        }
        return low
    }

    /// The match Find Next goes to from `selection`: the first starting at or after its end, or past it when the
    /// selection is an empty match itself; from the top when `wrapsAround`. Nil when there is none.
    public static func next(in matches: [NSRange], from selection: NSRange, wrapsAround: Bool) -> Int? {
        guard !matches.isEmpty else { return nil }
        let isEmptyMatch = selection.length == 0 && matches.contains(selection)
        let after = firstIndex(in: matches, atOrAfter: NSMaxRange(selection) + (isEmptyMatch ? 1 : 0))
        return after < matches.count ? after : (wrapsAround ? 0 : nil)
    }

    /// The match Find Previous goes to from `selection`: the last starting before it; from the bottom when
    /// `wrapsAround`. Nil when there is none.
    public static func previous(in matches: [NSRange], from selection: NSRange, wrapsAround: Bool) -> Int? {
        guard !matches.isEmpty else { return nil }
        let before = firstIndex(in: matches, atOrAfter: selection.location) - 1
        return before >= 0 ? before : (wrapsAround ? matches.count - 1 : nil)
    }

    /// `text` with every match of `expression` replaced by `template` (`$1` and the like refer to groups); nil when
    /// nothing matches. An empty match inserts the replacement there, so `^` prefixes every line.
    public static func replacingAll(of expression: NSRegularExpression, in text: String, with template: String) -> String? {
        let source = text as NSString
        let found = expression.matches(in: text, range: NSRange(location: 0, length: source.length))
        guard !found.isEmpty else { return nil }
        let result = NSMutableString(capacity: source.length)
        var end = 0
        for match in found {
            result.append(source.substring(with: NSRange(location: end, length: match.range.location - end)))
            result.append(expression.replacementString(for: match, in: text, offset: 0, template: template))
            end = NSMaxRange(match.range)
        }
        result.append(source.substring(from: end))
        return result as String
    }
}
