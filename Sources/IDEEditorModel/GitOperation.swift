import Foundation

/// A merge or a rebase git stopped in the middle of: it waits for the conflicts to be resolved, then for the merge's
/// commit or the rebase's next step, or for an abort. Read from the files git keeps in the git directory meanwhile
/// (`MERGE_HEAD`, `rebase-merge/`, `rebase-apply/`).
public struct GitOperation: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case merge
        case rebase
    }

    public var kind: Kind
    /// What comes in, by a name the user knows: the branch merged (`origin/main` after a pull) or the one a rebase
    /// replays the commits onto; the short commit id when no branch points there.
    public var incoming: String
    /// The branch a rebase rewrites (git detaches HEAD while it runs); nil for a merge, which stays on its branch.
    public var branch: String?
    /// The message git prepared for the merge's commit (`MERGE_MSG`) without its comment lines; nil for a rebase.
    public var message: String?

    public init(kind: Kind, incoming: String, branch: String? = nil, message: String? = nil) {
        self.kind = kind
        self.incoming = incoming
        self.branch = branch
        self.message = message
    }

    /// What git is in the middle of in the repository whose git directory is `gitDirectory`
    /// (`git rev-parse --absolute-git-dir`, a worktree's own); nil when it is in the middle of nothing.
    public static func read(gitDirectory: String, in directory: String) async -> GitOperation? {
        let files = FileManager.default
        func contents(_ name: String) -> String? {
            (try? String(contentsOfFile: gitDirectory + "/" + name, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let head = contents("MERGE_HEAD")?.split(separator: "\n").first.map(String.init), !head.isEmpty {
            let branch = contents("HEAD").flatMap { $0.hasPrefix("ref: refs/heads/") ? String($0.dropFirst(16)) : nil }
            return GitOperation(
                kind: .merge, incoming: await name(of: head, upstreamOf: branch, in: directory),
                message: contents("MERGE_MSG").map(withoutComments).flatMap { $0.isEmpty ? nil : $0 })
        }
        // `rebase-apply` without `applying` is a rebase by the apply backend; with it, `git am`, which is no rebase.
        for folder in ["rebase-merge", "rebase-apply"] where files.fileExists(atPath: gitDirectory + "/" + folder)
            && !files.fileExists(atPath: gitDirectory + "/" + folder + "/applying")
        {
            let onto = contents(folder + "/onto") ?? ""
            let head = contents(folder + "/head-name")
            let branch = head.flatMap { $0.hasPrefix("refs/heads/") ? String($0.dropFirst(11)) : nil }
            return GitOperation(
                kind: .rebase, incoming: onto.isEmpty ? "the upstream" : await name(of: onto, upstreamOf: branch, in: directory),
                branch: branch)
        }
        return nil
    }

    /// `branch`'s upstream when it is at `commit` (what a pull merges or rebases onto), else a local branch there, else
    /// a remote-tracking one (not a remote's `HEAD`), else the short commit id.
    private static func name(of commit: String, upstreamOf branch: String?, in directory: String) async -> String {
        let refs = (try? await Git.text(
            ["for-each-ref", "--points-at=\(commit)", "--format=%(refname)", "refs/heads/", "refs/remotes/"], in: directory))?
            .split(separator: "\n").map(String.init) ?? []
        if let branch, let upstream = try? await Git.text(["for-each-ref", "--format=%(upstream)", "refs/heads/" + branch], in: directory),
           refs.contains(upstream)
        {
            return shortName(upstream)
        }
        if let local = refs.first(where: { $0.hasPrefix("refs/heads/") }) { return shortName(local) }
        if let remote = refs.first(where: { $0.hasPrefix("refs/remotes/") && !$0.hasSuffix("/HEAD") }) { return shortName(remote) }
        return String(commit.prefix(7))
    }

    private static func shortName(_ ref: String) -> String {
        for prefix in ["refs/heads/", "refs/remotes/"] where ref.hasPrefix(prefix) { return String(ref.dropFirst(prefix.count)) }
        return ref
    }

    /// The message without the lines git comments out (`# Conflicts:` and the files under it) and the blank lines at
    /// its ends.
    static func withoutComments(_ message: String) -> String {
        message.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.hasPrefix("#") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// How Pull brings in what the upstream has.
public enum GitPull {
    /// `git pull` for `branch`, from `remote`'s branch of the same name when the branch tracks nothing yet. Diverged
    /// history is merged (`--no-rebase`), as Xcode, GitHub Desktop and git before 2.27 do, unless the user's git
    /// configuration says how to reconcile it: then git follows `branch.<name>.rebase`, `pull.rebase` and `pull.ff`
    /// as configured. (`--no-rebase` on the command line would turn a configured `pull.ff = only` into a merge.)
    /// Without either, git refuses a diverged pull outright.
    public static func arguments(branch: String, remote: String? = nil, in directory: String) async -> [String] {
        var arguments = ["pull", "--no-edit"]
        if await !reconcilingIsConfigured(for: branch, in: directory) { arguments.append("--no-rebase") }
        if let remote { arguments += [remote, branch] }
        return arguments
    }

    /// The user's configuration (any scope) says how pulls on `branch` reconcile diverged history.
    static func reconcilingIsConfigured(for branch: String, in directory: String) async -> Bool {
        for key in ["branch.\(branch).rebase", "pull.rebase", "pull.ff"] {
            // `git config --get` exits 1 for a key that is not set.
            if let value = try? await Git.text(["config", "--get", key], in: directory), !value.isEmpty { return true }
        }
        return false
    }
}

/// The changes Lantern sets aside to switch branches over them (Stash and Switch), kept as a stash on the branch they
/// were made on until Restore brings them back there.
public enum GitStash {
    /// One of Lantern's stashes.
    public struct Entry: Equatable, Sendable {
        /// Where it is in the stash list now: `stash@{index}`.
        public var index: Int
        /// The stash commit, to tell it apart from stashes made meanwhile.
        public var commit: String

        public var reference: String { "stash@{\(index)}" }
    }

    /// What marks a stash as Lantern's in `git stash list`: "On feature: Lantern: set aside to switch to main".
    static let marker = "Lantern: "

    /// The message of the stash that sets aside the changes on a branch to switch to `target`.
    public static func message(switchingTo target: String) -> String {
        marker + "set aside to switch to \(target)"
    }

    /// The newest of Lantern's stashes made on `branch`; nil when it has none.
    public static func newest(on branch: String, in directory: String) async -> Entry? {
        guard let list = try? await Git.text(["stash", "list", "--format=%gd%x1f%H%x1f%gs"], in: directory) else { return nil }
        for line in list.split(separator: "\n") {
            let fields = line.split(separator: "\u{1F}", maxSplits: 2, omittingEmptySubsequences: false)
            // `git stash push -m` records "On <branch>: <message>".
            guard fields.count == 3, fields[2].hasPrefix("On \(branch): \(marker)"),
                  let open = fields[0].firstIndex(of: "{"), let index = Int(fields[0][fields[0].index(after: open)...].dropLast())
            else { continue }
            return Entry(index: index, commit: String(fields[1]))
        }
        return nil
    }
}

/// The lines git writes into a file where a merge conflicts: `<<<<<<< ours`, `=======`, `>>>>>>> theirs`.
public enum ConflictMarkers {
    /// The text still has a conflict as git marked it: a line opening one (`<<<<<<<`) and a later line closing it
    /// (`>>>>>>>`), each the marker alone or followed by a space and a label.
    public static func present(in text: String) -> Bool {
        var opened = false
        for line in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            if !opened { opened = isMarker(line, "<<<<<<<") } else if isMarker(line, ">>>>>>>") { return true }
        }
        return false
    }

    private static func isMarker(_ line: Substring, _ marker: String) -> Bool {
        guard line.hasPrefix(marker) else { return false }
        let rest = line.dropFirst(marker.count)
        return rest.isEmpty || rest.first == " "
    }
}
