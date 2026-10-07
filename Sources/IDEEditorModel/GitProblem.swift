import Foundation

/// Why a git command failed, told from what it printed on stderr, in plain words for a notice: what happened and,
/// where there is one, what to do next. The kind lets the notice offer that next step (Pull after a rejected push).
public struct GitProblem: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// The remote's branch has commits this one lacks, so a push was refused (`! [rejected] … (fetch first)`).
        case remoteAhead
        /// Switching branches or merging would overwrite local changes to `files` (tracked or untracked), relative to
        /// the repository root.
        case changesOverwritten(files: [String])
        /// The branch and its upstream diverged, and `pull.ff = only` refuses to merge them.
        case cannotFastForward
        /// Files are still unmerged.
        case unresolvedConflicts
        /// A merge or a rebase is under way.
        case unfinishedOperation
        /// The remote, by name or by location, is not a repository git can reach.
        case noSuchRemote(String)
        /// The remote has no branch of that name (pulling a branch nobody pushed yet).
        case noRemoteBranch(String)
        case branchExists(String)
        /// The remote wants credentials git does not have (it never prompts here).
        case signInNeeded
        case remoteUnreachable
        /// Another git holds the repository's lock.
        case repositoryLocked
        case other
    }

    public let kind: Kind
    /// One or two sentences: what happened, and what to do when there is something to do.
    public let message: String

    /// Reads git's stderr; `status` is its exit status, for a git that printed nothing.
    public init(stderr: String, status: Int32 = 1) {
        let lines = stderr.split(whereSeparator: \.isNewline).map(String.init)
        func quoted(after prefix: String) -> String? {
            guard let line = lines.first(where: { $0.contains(prefix) }),
                  let start = line.range(of: prefix)?.upperBound,
                  let end = line[start...].firstIndex(of: "'")
            else { return nil }
            return String(line[start..<end])
        }
        if stderr.contains("[rejected]"), stderr.contains("(fetch first)") || stderr.contains("(non-fast-forward)") {
            self.init(.remoteAhead, "The remote has commits you don’t have. Pull them, then push again.")
        } else if let files = Self.overwrittenFiles(lines) {
            self.init(.changesOverwritten(files: files), "Your changes to \(Self.naming(files)) would be overwritten. Commit or stash them first.")
        } else if stderr.contains("Not possible to fast-forward") {
            self.init(.cannotFastForward, "The branches have diverged, and your git settings allow only fast-forward pulls.")
        } else if stderr.contains("You have not concluded your merge") || stderr.contains("MERGE_HEAD exists")
            || stderr.contains("cannot switch branch while merging")
        {
            self.init(.unfinishedOperation, "A merge is under way. Commit it or abort it first.")
        } else if stderr.contains("rebase-merge directory") || stderr.contains("rebase-apply directory")
            || stderr.contains("in the middle of a rebase") || stderr.contains("cannot switch branch while rebasing")
        {
            self.init(.unfinishedOperation, "A rebase is under way. Continue it or abort it first.")
        } else if stderr.contains("resolve your current index first") || stderr.contains("you have unmerged files")
            || stderr.contains("is unmerged")
        {
            self.init(.unresolvedConflicts, "Some files still have conflicts. Resolve them first.")
        } else if let remote = quoted(after: "fatal: '"), stderr.contains("does not appear to be a git repository") {
            let isLocation = remote.contains("/") || remote.contains(":")
            self.init(.noSuchRemote(remote), isLocation ? "There’s no repository at “\(remote)”." : "The repository has no remote named “\(remote)”.")
        } else if let line = lines.first(where: { $0.contains("couldn't find remote ref ") }),
                  let start = line.range(of: "couldn't find remote ref ")?.upperBound
        {
            let branch = line[start...].trimmingCharacters(in: .whitespaces)
            self.init(.noRemoteBranch(branch), "The remote has no branch “\(branch)” yet. Push to publish it.")
        } else if let branch = quoted(after: "a branch named '"), stderr.contains("already exists") {
            self.init(.branchExists(branch), "A branch named “\(branch)” already exists.")
        } else if stderr.contains("Permission denied (publickey") {
            self.init(.signInNeeded, "The remote refused your SSH key.")
        } else if stderr.contains("could not read Username") || stderr.contains("could not read Password")
            || stderr.contains("Authentication failed") || stderr.contains("terminal prompts disabled")
        {
            self.init(.signInNeeded, "The remote needs you to sign in. Sign in once with git in Terminal, then try again.")
        } else if ["Could not resolve host", "Couldn't resolve host", "Connection refused", "timed out", "Network is unreachable",
                   "Could not connect"].contains(where: stderr.contains)
        {
            self.init(.remoteUnreachable, "Can’t reach the remote. Check the network connection.")
        } else if stderr.contains(".lock': File exists") {
            self.init(.repositoryLocked, "Another git process is changing the repository. Try again once it’s done.")
        } else {
            self.init(.other, Self.sentence(from: lines) ?? "Git stopped with status \(status).")
        }
    }

    private init(_ kind: Kind, _ message: String) {
        self.kind = kind
        self.message = message
    }

    /// The files under git's "would be overwritten by checkout:" (or merge), tracked and untracked alike; nil when it
    /// says nothing of the kind.
    private static func overwrittenFiles(_ lines: [String]) -> [String]? {
        var files: [String] = []
        var listing = false
        var found = false
        for line in lines {
            if line.contains("would be overwritten by") && line.hasSuffix(":") {
                listing = true
                found = true
            } else if listing, line.hasPrefix("\t") {
                files.append(line.trimmingCharacters(in: .whitespaces))
            } else {
                listing = false
            }
        }
        return found ? files : nil
    }

    /// “a.txt”, “a.txt” and “b.txt”, “a.txt”, “b.txt” and 3 other files; by name, as the notice is narrow.
    public static func naming(_ files: [String]) -> String {
        let names = files.map { "“\(($0 as NSString).lastPathComponent)”" }
        switch names.count {
        case 0: return "some files"
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        case 3: return "\(names[0]), \(names[1]) and \(names[2])"
        default: return "\(names[0]), \(names[1]) and \(names.count - 2) other files"
        }
    }

    /// git's own reason as a sentence: its first `error:` or `fatal:` line without the prefix, else its first line that
    /// is neither a hint nor where it pushed or fetched (`To <url>`, `From <url>`).
    private static func sentence(from lines: [String]) -> String? {
        let prefixes = ["error: ", "fatal: "]
        let reason = lines.first { line in prefixes.contains { line.hasPrefix($0) } }
            .map { line in String(line.dropFirst(prefixes.first { line.hasPrefix($0) }?.count ?? 0)) }
            ?? lines.first { !$0.hasPrefix("hint:") && !$0.hasPrefix("To ") && !$0.hasPrefix("From ") && !$0.hasPrefix("\t") }
        guard var reason = reason?.trimmingCharacters(in: .whitespaces), let first = reason.first else { return nil }
        reason = first.uppercased() + reason.dropFirst()
        if let last = reason.last, !".!?".contains(last) { reason += "." }
        return reason
    }
}

/// What makes a branch name, after git's rules for refs (`git check-ref-format --branch`) and the branches there are.
public enum GitBranchName {
    /// Why `name` cannot name a new branch next to `existing` (the local branches), in Finder's words for names; nil
    /// when it can. git keeps branches as files under `.git/refs/heads` on a volume that may ignore case, so a name
    /// that differs from a branch only in case is taken, and one branch cannot be another's folder.
    public static func problem(_ name: String, existing: [String]) -> String? {
        if name.contains(where: \.isWhitespace) { return "Branch names can’t contain spaces." }
        if name.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) {
            return "Branch names can’t contain control characters."
        }
        if let character = name.first(where: { "~^:?*[\\".contains($0) }) { return "Branch names can’t contain “\(character)”." }
        for sequence in ["..", "@{", "//"] where name.contains(sequence) { return "Branch names can’t contain “\(sequence)”." }
        if name == "@" || name == "HEAD" { return "The name “\(name)” is reserved by git." }
        if name.hasPrefix("-") { return "Branch names can’t begin with “-”." }
        if name.hasPrefix("/") || name.hasSuffix("/") { return "Branch names can’t begin or end with “/”." }
        if name.hasSuffix(".") { return "Branch names can’t end with “.”." }
        let parts = name.split(separator: "/")
        if parts.contains(where: { $0.hasPrefix(".") }) { return "No part of a branch name can begin with “.”." }
        if parts.contains(where: { $0.hasSuffix(".lock") }) { return "No part of a branch name can end with “.lock”." }
        let lowered = name.lowercased()
        if let same = existing.first(where: { $0.lowercased() == lowered }) { return "A branch named “\(same)” already exists." }
        if let folder = existing.first(where: { lowered.hasPrefix($0.lowercased() + "/") }) {
            return "A branch named “\(folder)” exists, so a name can’t start with “\(folder)/”."
        }
        if existing.contains(where: { $0.lowercased().hasPrefix(lowered + "/") }) {
            return "Branches named “\(name)/…” exist, so “\(name)” can’t be a branch too."
        }
        return nil
    }
}
