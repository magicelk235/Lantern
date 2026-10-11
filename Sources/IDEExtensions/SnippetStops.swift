import Foundation

/// The tab stops of a snippet inserted in a text, in the order Tab visits them, kept where they are as the text is
/// edited. Each stop is one or more ranges: the first is where the caret goes (the primary), the others repeat it
/// (mirrors). A stop an edit cuts into is dropped, as VS Code drops a placeholder typed over.
public struct SnippetStops: Sendable, Equatable {
    private var stops: [[NSRange]]
    private var current = 0

    /// The stops of `expansion`, whose text starts at `location`.
    public init(_ expansion: SnippetExpansion, at location: Int) {
        stops = expansion.tabStops.map { stop in
            stop.ranges.map { NSRange(location: $0.location + location, length: $0.length) }
        }
    }

    public var count: Int { stops.count }

    /// The current stop's primary range; nil once it was dropped.
    public var primary: NSRange? { stops.indices.contains(current) ? stops[current].first : nil }

    /// The current stop's other ranges.
    public var mirrors: [NSRange] { stops.indices.contains(current) ? Array(stops[current].dropFirst()) : [] }

    /// Whether the current stop is the last one (`$0`, or the end of the snippet).
    public var isAtLast: Bool { current == stops.count - 1 }

    /// Moves `step` stops on (or back with a negative step), passing over dropped ones; false when that leaves the
    /// snippet, at either end.
    public mutating func advance(by step: Int) -> Bool {
        var next = current + step
        while stops.indices.contains(next), stops[next].isEmpty { next += step }
        guard stops.indices.contains(next) else { return false }
        current = next
        return true
    }

    /// `range` of the text was replaced with `newLength` characters: every stop moves with the text. True when the edit
    /// was inside the current stop's primary range (typing in the placeholder, including at either end of it).
    ///
    /// An edit inside another stop grows or shrinks it; one before a stop moves it, as does an insertion right at the
    /// start of a stop other than the current one (the text typed at the end of the stop before it belongs there); one
    /// that cuts into a stop, or covers it, drops that range.
    @discardableResult
    public mutating func replace(_ range: NSRange, newLength: Int) -> Bool {
        let delta = newLength - range.length
        let start = range.location
        let end = NSMaxRange(range)
        var inPrimary = false
        for index in stops.indices {
            let isCurrent = index == current
            stops[index] = stops[index].enumerated().compactMap { offset, stop in
                let stopStart = stop.location
                let stopEnd = NSMaxRange(stop)
                let insertsAtStart = range.length == 0 && start == stopStart
                if start >= stopStart, end <= stopEnd, isCurrent || !insertsAtStart {
                    if isCurrent && offset == 0 { inPrimary = true }
                    return NSRange(location: stopStart, length: stop.length + delta)
                }
                if end <= stopStart {
                    return NSRange(location: stopStart + delta, length: stop.length)
                }
                if start >= stopEnd { return stop }
                return nil
            }
        }
        return inPrimary
    }
}
