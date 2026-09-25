/// A line diff between two texts, grouped into unified-diff hunks.
public enum LineDiff {
    public struct Line: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            /// In both texts.
            case context
            /// Only in the old text.
            case removed
            /// Only in the new text.
            case inserted
        }

        public var kind: Kind
        /// 1-based line number in the old text; nil for an inserted line.
        public var oldNumber: Int?
        /// 1-based line number in the new text; nil for a removed line.
        public var newNumber: Int?
        /// The line without its line break.
        public var text: String
    }

    /// Consecutive changes with up to `context` unchanged lines around them.
    public struct Hunk: Equatable, Sendable {
        public var lines: [Line]

        /// `@@ -a,b +c,d @@`, as in a unified diff.
        public var header: String {
            let oldCount = lines.filter { $0.kind != .inserted }.count
            let newCount = lines.filter { $0.kind != .removed }.count
            let oldStart = lines.first { $0.oldNumber != nil }?.oldNumber ?? 0
            let newStart = lines.first { $0.newNumber != nil }?.newNumber ?? 0
            return "@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@"
        }
    }

    /// The hunks turning `old` into `new`; empty when their lines are equal. Lines end at `\n` (a `\r` before it
    /// stays part of the line) and a text ending with a line break has an empty last line.
    public static func hunks(from old: String, to new: String, context: Int = 3) -> [Hunk] {
        let oldLines = old.split(separator: "\n", omittingEmptySubsequences: false)
        let newLines = new.split(separator: "\n", omittingEmptySubsequences: false)
        let difference = newLines.difference(from: oldLines)
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }

        // Lines kept in both texts pair up in order; changes go removals first, as in a unified diff.
        var all: [Line] = []
        var oldIndex = 0
        var newIndex = 0
        while oldIndex < oldLines.count || newIndex < newLines.count {
            if oldIndex < oldLines.count, removed.contains(oldIndex) {
                all.append(Line(kind: .removed, oldNumber: oldIndex + 1, newNumber: nil, text: String(oldLines[oldIndex])))
                oldIndex += 1
            } else if newIndex < newLines.count, inserted.contains(newIndex) {
                all.append(Line(kind: .inserted, oldNumber: nil, newNumber: newIndex + 1, text: String(newLines[newIndex])))
                newIndex += 1
            } else {
                all.append(Line(kind: .context, oldNumber: oldIndex + 1, newNumber: newIndex + 1, text: String(oldLines[oldIndex])))
                oldIndex += 1
                newIndex += 1
            }
        }

        var hunks: [Hunk] = []
        var current: Range<Int>?
        for (index, line) in all.enumerated() where line.kind != .context {
            let range = max(0, index - context)..<min(all.count, index + context + 1)
            if let open = current, range.lowerBound <= open.upperBound {
                current = open.lowerBound..<max(open.upperBound, range.upperBound)
            } else {
                if let open = current { hunks.append(Hunk(lines: Array(all[open]))) }
                current = range
            }
        }
        if let open = current { hunks.append(Hunk(lines: Array(all[open]))) }
        return hunks
    }
}
