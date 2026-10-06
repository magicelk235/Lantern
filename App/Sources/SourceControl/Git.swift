import Foundation

/// What `git status --porcelain=v2 -z --branch` says: the branch and its upstream, and every path that differs
/// between HEAD, the index and the work tree. Paths are relative to the repository root, whatever the folder git ran
/// in.
struct GitStatus: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        /// Relative to the repository root.
        var path: String
        /// Where a renamed or copied file came from, for `index == "R"` or `"C"`.
        var originalPath: String?
        /// The index against HEAD (the `X` of git's `XY`): `M`, `A`, `D`, `R`, `C`, `T`; `.` for no difference.
        var index: Character
        /// The work tree against the index (the `Y`): `M`, `D`, `T`; `.` for no difference.
        var workTree: Character
        /// Not in the index and not ignored (`?`).
        var isUntracked: Bool
        /// A merge left the path unmerged (`u`): `index` and `workTree` are git's two stage letters.
        var isConflicted: Bool

        /// Something to stage: the work tree differs from the index, or nothing tracks the file yet.
        var hasWorkTreeChange: Bool { isUntracked || isConflicted || workTree != "." }
        /// Something to commit: the index differs from HEAD.
        var isStaged: Bool { !isUntracked && !isConflicted && index != "." }
    }

    /// The commit HEAD points at; nil on a branch without commits yet.
    var oid: String?
    /// The branch; nil when HEAD is detached.
    var head: String?
    /// The tracking branch (`origin/main`), when the branch has one.
    var upstream: String?
    /// Commits the branch has that its upstream lacks, and the reverse; 0 without an upstream.
    var ahead = 0
    var behind = 0
    var entries: [Entry] = []

    /// Parses the NUL-separated records of `git status --porcelain=v2 -z --branch`.
    static func parse(_ output: Data) -> GitStatus {
        var status = GitStatus()
        let records = output.split(separator: 0, omittingEmptySubsequences: true).map { String(decoding: $0, as: UTF8.self) }
        var index = 0
        while index < records.count {
            let record = records[index]
            index += 1
            switch record.first {
            case "#":
                status.parseHeader(record)
            case "1":
                let fields = record.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: false)
                guard fields.count == 9 else { continue }
                status.entries.append(Entry(path: String(fields[8]), xy: fields[1]))
            case "2":
                let fields = record.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: false)
                guard fields.count == 10, index < records.count else { continue }
                // The original path follows as its own record.
                var entry = Entry(path: String(fields[9]), xy: fields[1])
                entry.originalPath = records[index]
                index += 1
                status.entries.append(entry)
            case "u":
                let fields = record.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false)
                guard fields.count == 11 else { continue }
                var entry = Entry(path: String(fields[10]), xy: fields[1])
                entry.isConflicted = true
                status.entries.append(entry)
            case "?":
                var entry = Entry(path: String(record.dropFirst(2)), xy: "..")
                entry.isUntracked = true
                status.entries.append(entry)
            default:
                // `!` (ignored, never asked for) and anything a newer git adds.
                continue
            }
        }
        return status
    }

    private mutating func parseHeader(_ record: String) {
        let fields = record.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard fields.count == 3 else { return }
        let value = String(fields[2])
        switch fields[1] {
        case "branch.oid": oid = value == "(initial)" ? nil : value
        case "branch.head": head = value == "(detached)" ? nil : value
        case "branch.upstream": upstream = value
        case "branch.ab":
            let counts = value.split(separator: " ")
            guard counts.count == 2 else { return }
            ahead = Int(counts[0].dropFirst()) ?? 0
            behind = Int(counts[1].dropFirst()) ?? 0
        default: break
        }
    }
}

extension GitStatus.Entry {
    fileprivate init(path: String, xy: Substring) {
        var letters = xy.makeIterator()
        self.init(
            path: path, originalPath: nil, index: letters.next() ?? ".", workTree: letters.next() ?? ".",
            isUntracked: false, isConflicted: false)
    }
}
