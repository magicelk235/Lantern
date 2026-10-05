import Foundation
import LanguageServerProtocol

/// Where each line of a text starts, to turn the editor's UTF-16 offsets into LSP positions and back. LSP counts a
/// position's character in UTF-16 code units (the default `positionEncoding`, the only one omp IDE offers) and breaks
/// lines after "\n", "\r\n" and a lone "\r" — not after U+2028 and friends, which `NSString`'s line ranges also break at.
///
/// The table follows edits (`replace`) without reading more of the text than the lines around the edit, so the editor
/// can describe each change in positions of the text before it (`textDocument/didChange`).
public struct LineTable: Sendable, Equatable {
    /// The offset each line starts at, ascending; the first is 0. A text ending with a line break has an empty last
    /// line starting at its end.
    private var starts: [Int]
    /// The text's length in UTF-16 code units.
    public private(set) var length: Int

    public init(_ text: NSString) {
        length = text.length
        starts = [0]
        Self.appendStarts(in: text, from: 1, through: length, to: &starts)
    }

    public var lineCount: Int { starts.count }

    public func lineStart(_ line: Int) -> Int { starts[line] }

    /// The line holding `offset` (clamped to the text) and the offset's distance from that line's start.
    public func position(at offset: Int) -> Position {
        let offset = min(max(0, offset), length)
        let line = self.line(containing: offset)
        return Position(line: line, character: offset - starts[line])
    }

    /// The offset of `position` in `text` (the text this table describes). As LSP asks, a line past the last is the
    /// end of the text and a character past a line's end is the end of its text, before its line break.
    public func offset(at position: Position, in text: NSString) -> Int {
        guard position.line >= 0 else { return 0 }
        guard position.line < starts.count else { return length }
        let start = starts[position.line]
        return start + min(max(0, position.character), contentEnd(ofLine: position.line, in: text) - start)
    }

    public func lspRange(of range: NSRange) -> LSPRange {
        LSPRange(start: position(at: range.location), end: position(at: NSMaxRange(range)))
    }

    /// `range` in `text` as UTF-16 offsets; an end before the start is the start.
    public func range(of range: LSPRange, in text: NSString) -> NSRange {
        let start = offset(at: range.start, in: text)
        return NSRange(location: start, length: max(0, offset(at: range.end, in: text) - start))
    }

    /// The text changed: `range` of the text before was replaced with `newLength` code units, and `text` is the text
    /// after. Only the line starts the edit can have moved are looked at again: a line starts at `p` when the code unit
    /// before it is "\n", or "\r" not followed by "\n", so the starts inside the edit and right after it are decided
    /// anew and those further on shift by the change in length.
    public mutating func replace(_ range: NSRange, newLength: Int, in text: NSString) {
        let editStart = range.location
        let oldEnd = NSMaxRange(range)
        let delta = newLength - range.length
        // Old starts in editStart...oldEnd (never line 0's) go; the ones after shift.
        let firstRemoved = max(1, firstIndex(atOrAfter: editStart))
        let firstKept = firstIndex(atOrAfter: oldEnd + 1)
        var inserted: [Int] = []
        Self.appendStarts(in: text, from: max(1, editStart), through: min(editStart + newLength, text.length), to: &inserted)
        if firstKept < starts.count, delta != 0 {
            for index in firstKept..<starts.count { starts[index] += delta }
        }
        starts.replaceSubrange(firstRemoved..<max(firstRemoved, firstKept), with: inserted)
        length = text.length
    }

    // MARK: - Lookup

    private func line(containing offset: Int) -> Int {
        // The last start at or before `offset`.
        firstIndex(atOrAfter: offset + 1) - 1
    }

    /// The index of the first start at or after `offset` (`starts.count` when there is none).
    private func firstIndex(atOrAfter offset: Int) -> Int {
        var low = 0
        var high = starts.count
        while low < high {
            let middle = (low + high) / 2
            if starts[middle] < offset { low = middle + 1 } else { high = middle }
        }
        return low
    }

    /// Where line `line`'s text ends: before its line break, or the end of the text for the last line.
    private func contentEnd(ofLine line: Int, in text: NSString) -> Int {
        guard line + 1 < starts.count else { return length }
        var end = starts[line + 1]
        if end > starts[line], text.character(at: end - 1) == Self.lineFeed { end -= 1 }
        if end > starts[line], text.character(at: end - 1) == Self.carriageReturn { end -= 1 }
        return end
    }

    // MARK: - Scanning

    private static let lineFeed: unichar = 0x0A
    private static let carriageReturn: unichar = 0x0D
    /// Code units read at a time, so a large text is never copied whole.
    private static let chunk = 16 * 1024

    /// Appends, ascending, the offsets in `lower...upper` (each at least 1) that start a line of `text`.
    private static func appendStarts(in text: NSString, from lower: Int, through upper: Int, to starts: inout [Int]) {
        let lower = max(1, lower)
        guard lower <= upper else { return }
        let length = text.length
        withUnsafeTemporaryAllocation(of: unichar.self, capacity: chunk + 1) { buffer in
            var first = lower
            while first <= upper {
                let last = min(upper, first + chunk - 1)
                // The code units before and at each candidate: first - 1 ..< last + 1, clipped to the text.
                let readStart = first - 1
                let readEnd = min(last + 1, length)
                text.getCharacters(buffer.baseAddress!, range: NSRange(location: readStart, length: readEnd - readStart))
                for offset in first...last {
                    let before = buffer[offset - 1 - readStart]
                    if before == lineFeed {
                        starts.append(offset)
                    } else if before == carriageReturn, offset == length || buffer[offset - readStart] != lineFeed {
                        starts.append(offset)
                    }
                }
                first = last + 1
            }
        }
    }
}
