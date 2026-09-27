import AppKit
import IDEEditorModel

/// The git repository of one project folder: its branch, the local branches, what changed, and the actions of the
/// Changes panel and the Source Control menu. Every git call runs off the main thread; the state here is what the
/// last `refresh` saw. One action at a time (`isBusy`); a refresh follows each.
@MainActor @Observable
final class GitRepository {
    /// One path that differs between HEAD, the index and the work tree.
    struct Change: Hashable, Identifiable, Sendable {
        /// Absolute.
        let path: String
        /// Relative to the repository root, as git names it (`HEAD:<relativePath>`).
        let relativePath: String
        /// Where a rename or copy came from, relative to the repository root.
        let originalPath: String?
        /// The index against HEAD, `nil` when they agree; `M`, `A`, `D`, `R`, `C` or `T`.
        let staged: Character?
        /// The work tree against the index, `nil` when they agree; `M`, `D`, `T`, `?` untracked, `U` unmerged.
        let unstaged: Character?

        var id: String { relativePath }
        var name: String { (path as NSString).lastPathComponent }
        var isUntracked: Bool { unstaged == "?" }
        var isConflicted: Bool { unstaged == "U" }
        /// HEAD has no version of the file: nothing to diff against but the empty text.
        var isNewToHead: Bool { isUntracked || staged == "A" }
    }

    /// Why an action failed, for the panel's notice.
    struct Failure: Equatable {
        let title: String
        let message: String
    }

    /// The work tree against HEAD, for `ChangeDiffSheet`.
    struct Comparison: Identifiable {
        let id = UUID()
        let change: Change
        let hunks: [LineDiff.Hunk]
    }

    let workspace: String
    /// The first refresh is in: until then the panel shows nothing rather than "not a repository".
    private(set) var hasLoaded = false
    private(set) var isRepository = false
    /// The branch; nil when HEAD is detached (`headCommit` says where).
    private(set) var branch: String?
    /// The commit HEAD points at, abbreviated; nil on a branch without commits.
    private(set) var headCommit: String?
    /// Local branches, sorted.
    private(set) var branches: [String] = []
    private(set) var hasUpstream = false
    private(set) var ahead = 0
    private(set) var behind = 0
    /// Sorted by path, as git lists them.
    private(set) var changes: [Change] = []
    var lastError: Failure?
    /// An action runs; the panel and the menu wait for it.
    private(set) var isBusy = false
    /// The draft, kept while the panel is away.
    var commitMessage = ""
    var comparison: Comparison?
    /// The New Branch sheet is up.
    var isNamingBranch = false

    @ObservationIgnored private var refreshing: Task<Void, Never>?
    /// A refresh was asked for while one ran: run once more afterwards.
    @ObservationIgnored private var refreshStale = false

    /// git was found (see `Git.executable`); known once the first refresh is in.
    private(set) var isGitAvailable = true

    init(workspace: String) {
        self.workspace = workspace
    }

    var stagedChanges: [Change] { changes.filter { $0.staged != nil } }
    var unstagedChanges: [Change] { changes.filter { $0.unstaged != nil } }
    /// A commit can go: something is staged and the message says what.
    var canCommit: Bool { isRepository && !isBusy && !stagedChanges.isEmpty && !trimmedMessage.isEmpty }
    /// Stage All and Commit can go: something changed and the message says what.
    var canStageAllAndCommit: Bool { isRepository && !isBusy && !changes.isEmpty && !trimmedMessage.isEmpty }

    private var trimmedMessage: String { commitMessage.trimmingCharacters(in: .whitespacesAndNewlines) }

    // MARK: - Refresh

    /// Asks git again for the branch, its upstream, the local branches and the changes; at most one run at a time, and
    /// one more if asked for meanwhile.
    func refresh() {
        guard refreshing == nil else {
            refreshStale = true
            return
        }
        refreshing = Task { [workspace] in
            let outcome = await Task.detached(priority: .userInitiated) { Self.load(workspace) }.value
            apply(outcome)
            refreshing = nil
            if refreshStale {
                refreshStale = false
                refresh()
            }
        }
    }

    /// What one refresh read.
    private struct Snapshot: Sendable {
        var status: GitStatus
        var branches: [String]
        var changes: [Change]
    }

    private enum Outcome: Sendable {
        case repository(Snapshot)
        case notRepository
        /// Neither the developer directory nor Homebrew has git.
        case noGit
        case failed(String)
    }

    nonisolated private static func load(_ workspace: String) -> Outcome {
        guard Git.executable != nil else { return .noGit }
        let toplevel: String
        let prefix: String
        do {
            let lines = try Git.text(["rev-parse", "--show-toplevel", "--show-prefix"], in: workspace)
                .split(separator: "\n", omittingEmptySubsequences: false)
            toplevel = lines.first.map(String.init) ?? workspace
            prefix = lines.count > 1 ? String(lines[1]) : ""
        } catch let failure as Git.Failure where failure.status == 128 && failure.stderr.contains("not a git repository") {
            return .notRepository
        } catch {
            return .failed(String(describing: error))
        }
        do {
            let status = GitStatus.parse(
                try Git.output(["status", "--porcelain=v2", "-z", "--branch", "--untracked-files=all"], in: workspace))
            let branches = try Git.text(["for-each-ref", "--format=%(refname:short)", "refs/heads/"], in: workspace)
                .split(separator: "\n").map(String.init)
            let changes = status.entries.map { entry in
                Change(
                    path: absolutePath(entry.path, workspace: workspace, toplevel: toplevel, prefix: prefix),
                    relativePath: entry.path, originalPath: entry.originalPath,
                    staged: entry.isStaged ? entry.index : nil,
                    unstaged: entry.isUntracked ? "?" : entry.isConflicted ? "U" : entry.workTree == "." ? nil : entry.workTree)
            }
            return .repository(Snapshot(status: status, branches: branches, changes: changes))
        } catch {
            return .failed(String(describing: error))
        }
    }

    /// git names paths from the repository root; the app names them under the project folder as given (a symlinked
    /// folder keeps its spelling). A path outside the project, in a repository above it, is spelled from the root.
    nonisolated private static func absolutePath(_ path: String, workspace: String, toplevel: String, prefix: String) -> String {
        if prefix.isEmpty { return workspace + "/" + path }
        if path.hasPrefix(prefix) { return workspace + "/" + String(path.dropFirst(prefix.count)) }
        return toplevel + "/" + path
    }

    private func apply(_ outcome: Outcome) {
        hasLoaded = true
        switch outcome {
        case .repository(let snapshot):
            isRepository = true
            branch = snapshot.status.head
            headCommit = snapshot.status.oid.map { String($0.prefix(7)) }
            branches = snapshot.branches
            hasUpstream = snapshot.status.upstream != nil
            ahead = snapshot.status.ahead
            behind = snapshot.status.behind
            if changes != snapshot.changes { changes = snapshot.changes }
        case .noGit:
            isGitAvailable = false
            isRepository = false
        case .notRepository:
            isRepository = false
            branch = nil
            headCommit = nil
            branches = []
            hasUpstream = false
            ahead = 0
            behind = 0
            changes = []
        case .failed(let message):
            lastError = Failure(title: "Could not read the repository", message: message)
        }
    }

    // MARK: - Actions

    /// `git add -A -- <paths>`.
    func stage(_ changes: [Change]) {
        guard !changes.isEmpty else { return }
        perform("Could not stage " + Self.naming(changes), ["add", "-A", "--"] + changes.map(\.relativePath))
    }

    /// `git reset -q -- <paths>` (and the paths renames came from), which unlike `restore --staged` works on a branch
    /// without commits.
    func unstage(_ changes: [Change]) {
        guard !changes.isEmpty else { return }
        let paths = changes.flatMap { [$0.relativePath] + ($0.originalPath.map { [$0] } ?? []) }
        perform("Could not unstage " + Self.naming(changes), ["reset", "-q", "--"] + paths)
    }

    /// “name” for one file, else how many.
    private static func naming(_ changes: [Change]) -> String {
        changes.count == 1 ? "“\(changes[0].name)”" : "\(changes.count) files"
    }

    /// `git add -A`.
    func stageAll() {
        perform("Could not stage the changes", ["add", "-A"])
    }

    /// The work tree copy goes back to the index (`git restore --worktree -- <path>`); a file git does not track goes
    /// to the Trash instead. Asked first (`SourceControlPanel`).
    func discard(_ change: Change) {
        if change.isUntracked {
            run("Could not discard “\(change.name)”") { [path = change.path] in
                try FileManager.default.trashItem(at: URL(filePath: path), resultingItemURL: nil)
            }
        } else {
            perform("Could not discard “\(change.name)”", ["restore", "--worktree", "--", change.relativePath])
        }
    }

    /// `git commit -m <message>`, after `git add -A` when `stagingAll`. The draft clears once it is in.
    func commit(stagingAll: Bool = false) {
        let message = trimmedMessage
        guard stagingAll ? canStageAllAndCommit : canCommit else { return }
        run("Could not commit", { [workspace] in
            if stagingAll { _ = try Git.output(["add", "-A"], in: workspace) }
            _ = try Git.output(["commit", "-m", message], in: workspace)
        }) { [self] in
            commitMessage = ""
        }
    }

    /// `git fetch`.
    func fetch() {
        perform("Could not fetch", ["fetch"])
    }

    /// `git pull --no-edit`; from `origin <branch>` when the branch tracks nothing yet.
    func pull() {
        guard let branch else { return }
        perform("Could not pull", ["pull", "--no-edit"] + (hasUpstream ? [] : ["origin", branch]))
    }

    /// `git push`; `-u origin <branch>` when the branch tracks nothing yet.
    func push() {
        guard let branch else { return }
        perform("Could not push", ["push"] + (hasUpstream ? [] : ["-u", "origin", branch]))
    }

    /// `git switch <name>`.
    func switchBranch(_ name: String) {
        guard name != branch else { return }
        perform("Could not switch to “\(name)”", ["switch", name])
    }

    /// Opens the New Branch sheet; an earlier failure leaves, so the sheet only ever shows its own.
    func beginNamingBranch() {
        lastError = nil
        isNamingBranch = true
    }

    /// `git switch -c <name>`: made from HEAD and checked out. The sheet closes once it exists.
    func createBranch(_ name: String) {
        perform("Could not create “\(name)”", ["switch", "-c", name]) { [self] in isNamingBranch = false }
    }

    /// `git init` in the project folder.
    func initialize() {
        perform("Could not initialize a repository", ["init"])
    }

    /// Diffs HEAD's version of the file (`git show HEAD:<path>`, the empty text for a file HEAD lacks) against the
    /// work tree, off the main thread, then shows it in a sheet.
    func compare(_ change: Change) {
        Task { [workspace] in
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<[LineDiff.Hunk], Error> in
                do {
                    let base = change.isNewToHead
                        ? "" : String(decoding: try Git.output(["show", "HEAD:\(change.originalPath ?? change.relativePath)"], in: workspace), as: UTF8.self)
                    let current: String
                    switch TextFile.read(change.path) {
                    case .text(let snapshot): current = snapshot.text
                    case .missing: current = ""
                    case .unsupported(let reason): throw UnsupportedFile(reason: reason)
                    }
                    return .success(LineDiff.hunks(from: base, to: current))
                } catch {
                    return .failure(error)
                }
            }.value
            switch outcome {
            case .success(let hunks): comparison = Comparison(change: change, hunks: hunks)
            case .failure(let error): lastError = Failure(title: "Could not compare “\(change.name)”", message: String(describing: error))
            }
        }
    }

    private struct UnsupportedFile: Error, CustomStringConvertible {
        let reason: UnsupportedReason
        var description: String {
            switch reason {
            case .tooLarge: "The file is too large to show as text."
            case .binary: "The file is not a text file."
            case .directory: "The path is a folder."
            case .unreadable(let message): message
            }
        }
    }

    /// Runs one git command as an action.
    private func perform(_ failureTitle: String, _ arguments: [String], then completion: (@MainActor @Sendable () -> Void)? = nil) {
        run(failureTitle, { [workspace] in _ = try Git.output(arguments, in: workspace) }, then: completion)
    }

    /// Runs `work` off the main thread as the one action under way; its failure becomes `lastError`, and a refresh
    /// follows either way.
    private func run(_ failureTitle: String, _ work: @escaping @Sendable () throws -> Void, then completion: (@MainActor @Sendable () -> Void)? = nil) {
        guard !isBusy else { return }
        isBusy = true
        lastError = nil
        Task {
            let failure = await Task.detached(priority: .userInitiated) { () -> String? in
                do {
                    try work()
                    return nil
                } catch {
                    return String(describing: error)
                }
            }.value
            if let failure {
                lastError = Failure(title: failureTitle, message: failure)
            } else {
                completion?()
            }
            isBusy = false
            refresh()
        }
    }
}

/// The repositories of the project folders, one each, made when first asked for; FSEvents changes under a project
/// (its files, or `.git` after a commit in a terminal) refresh its repository half a second after they settle.
@MainActor @Observable
final class GitRepositories {
    /// Source Control › Commit… asked for the commit message field; the panel takes it and clears this.
    var commitFocusPending = false

    @ObservationIgnored private var repositories: [String: GitRepository] = [:]
    @ObservationIgnored private var changedRoots: Set<String> = []
    @ObservationIgnored private var pendingRefresh: Task<Void, Never>?

    /// The repository of `workspace`, refreshed once when made.
    func repository(for workspace: String) -> GitRepository {
        if let repository = repositories[workspace] { return repository }
        let repository = GitRepository(workspace: workspace)
        repositories[workspace] = repository
        repository.refresh()
        return repository
    }

    /// `Editors` saw FSEvents changes under `root`.
    func filesChanged(under root: String) {
        changedRoots.insert(root)
        pendingRefresh?.cancel()
        pendingRefresh = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            let roots = changedRoots
            changedRoots = []
            for repository in repositories.values where roots.contains(where: { repository.workspace == $0 || repository.workspace.hasPrefix($0 + "/") }) {
                repository.refresh()
            }
        }
    }
}
