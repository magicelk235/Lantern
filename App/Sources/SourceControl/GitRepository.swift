import AppKit
import IDEEditorModel

/// The git repository of one project folder: its branch, the local branches, what changed, a merge or rebase git
/// stopped in, and the actions of the Changes panel and the Source Control menu. Every git call runs off the main
/// thread; the state here is what the last `refresh` saw. One action at a time (`isBusy`); a refresh follows each.
/// What cannot be taken back is asked about first, in a sheet on the key window.
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
        /// The work tree against the index, `nil` when they agree; `M`, `D`, `T`, `U` untracked, `!` unmerged (VS Code's
        /// letters, which the Files pane shares).
        let unstaged: Character?
        /// For a conflicted file: the index still holds our side's version, their side's (a side that deleted the
        /// file has none).
        var hasOurVersion = false
        var hasTheirVersion = false

        var id: String { relativePath }
        var name: String { (path as NSString).lastPathComponent }
        var isUntracked: Bool { unstaged == "U" }
        var isConflicted: Bool { unstaged == "!" }
        /// HEAD has no version of the file: nothing to diff against but the empty text.
        var isNewToHead: Bool { isUntracked || staged == "A" }
    }

    /// Why an action failed, for the panel's notice: what happened in plain words, git's own text for the tooltip,
    /// and the next step when there is one.
    struct Failure: Equatable {
        let title: String
        let message: String
        /// What git printed on stderr; empty when the message is all there is.
        var details = ""
        var remedy: Remedy?
    }

    /// The next step a failure's notice offers.
    enum Remedy: Equatable {
        /// The remote has commits the branch lacks.
        case pull
        /// The remote has no branch of this name yet.
        case push

        var title: String {
            switch self {
            case .pull: "Pull"
            case .push: "Push"
            }
        }
    }

    /// The side of a conflict Take Mine and Take Theirs keep.
    enum Side {
        /// The branch's own version.
        case mine
        /// What the merge or rebase brings in.
        case theirs
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
    /// The remotes by name (`git remote`): Fetch, Pull and Push need one.
    private(set) var remotes: [String] = []
    /// A merge or a rebase git stopped in, waiting for the conflicts to be resolved and its commit or next step.
    private(set) var operation: GitOperation?
    /// Lantern's stash of the changes on this branch (Stash and Switch), until Restore brings them back.
    private(set) var stash: GitStash.Entry?
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
    /// The message a merge put into the empty message field, taken out again if it is still there when the merge ends.
    @ObservationIgnored private var mergeMessage: String?

    /// git was found (see `Git.executable`); known once the first refresh is in.
    private(set) var isGitAvailable = true

    init(workspace: String) {
        self.workspace = workspace
    }

    /// The Conflicts list: files a merge, a rebase or a restored stash left unmerged.
    var conflictedChanges: [Change] { changes.filter(\.isConflicted) }
    var stagedChanges: [Change] { changes.filter { $0.staged != nil } }
    /// The Changes list: the work tree against the index, conflicts aside.
    var unstagedChanges: [Change] { changes.filter { $0.unstaged != nil && !$0.isConflicted } }
    var isMerging: Bool { operation?.kind == .merge }
    /// A commit can go: the message says what, nothing is unmerged, and something is staged or a merge waits for its
    /// commit (resolving every conflict with the branch's side leaves nothing staged).
    var canCommit: Bool {
        isRepository && !isBusy && conflictedChanges.isEmpty && !trimmedMessage.isEmpty && (isMerging || !stagedChanges.isEmpty)
    }
    /// Stage All and Commit can go: the message says what, nothing is unmerged, and something changed or a merge
    /// waits for its commit.
    var canStageAllAndCommit: Bool {
        isRepository && !isBusy && conflictedChanges.isEmpty && !trimmedMessage.isEmpty && (isMerging || !changes.isEmpty)
    }
    var canFetch: Bool { isRepository && !isBusy && !remotes.isEmpty }
    /// Pull waits for a merge or rebase under way to be done, as switching branches does.
    var canPull: Bool { canFetch && branch != nil && operation == nil }
    var canPush: Bool { canFetch && branch != nil }
    var canSwitchBranch: Bool { isRepository && !isBusy && operation == nil }

    private var trimmedMessage: String { commitMessage.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// Where a branch without upstream pushes and pulls: `origin`, else the only remote.
    private var defaultRemote: String? { remotes.contains("origin") ? "origin" : remotes.first }

    // MARK: - Refresh

    /// Asks git again for the branch, its upstream, the local branches, the remotes, the changes, what git is in the
    /// middle of and Lantern's stash on the branch; at most one run at a time, and one more if asked for meanwhile.
    func refresh() {
        guard refreshing == nil else {
            refreshStale = true
            return
        }
        refreshing = Task { [workspace] in
            let outcome = await Task.detached(priority: .userInitiated) { await Self.load(workspace) }.value
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
        var remotes: [String]
        var changes: [Change]
        var operation: GitOperation?
        var stash: GitStash.Entry?
    }

    private enum Outcome: Sendable {
        case repository(Snapshot)
        case notRepository
        /// Neither the developer directory nor Homebrew has git.
        case noGit
        case failed(any Error)
    }

    nonisolated private static func load(_ workspace: String) async -> Outcome {
        guard Git.executable != nil else { return .noGit }
        let toplevel: String
        let prefix: String
        let gitDirectory: String
        do {
            let lines = try await Git.text(["rev-parse", "--show-toplevel", "--show-prefix", "--absolute-git-dir"], in: workspace)
                .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            toplevel = lines.first ?? workspace
            prefix = lines.count > 1 ? lines[1] : ""
            gitDirectory = lines.count > 2 ? lines[2] : toplevel + "/.git"
        } catch let failure as Git.Failure where failure.status == 128 && failure.stderr.contains("not a git repository") {
            return .notRepository
        } catch {
            return .failed(error)
        }
        do {
            async let statusOutput = Git.output(["status", "--porcelain=v2", "-z", "--branch", "--untracked-files=all"], in: workspace)
            async let branchList = Git.text(["for-each-ref", "--format=%(refname:short)", "refs/heads/"], in: workspace)
            async let remoteList = Git.text(["remote"], in: workspace)
            async let reading = GitOperation.read(gitDirectory: gitDirectory, in: workspace)
            let status = GitStatus.parse(try await statusOutput)
            let branches = try await branchList.split(separator: "\n").map(String.init)
            let remotes = try await remoteList.split(separator: "\n").map(String.init)
            let operation = await reading
            // A rebase detaches HEAD from the branch it rewrites.
            var stash: GitStash.Entry?
            if let branch = status.head ?? operation?.branch { stash = await GitStash.newest(on: branch, in: workspace) }
            let changes = status.entries.map { entry in
                Change(
                    path: absolutePath(entry.path, workspace: workspace, toplevel: toplevel, prefix: prefix),
                    relativePath: entry.path, originalPath: entry.originalPath,
                    staged: entry.isStaged ? entry.index : nil,
                    unstaged: entry.isUntracked ? "U" : entry.isConflicted ? "!" : entry.workTree == "." ? nil : entry.workTree,
                    hasOurVersion: entry.hasOurVersion, hasTheirVersion: entry.hasTheirVersion)
            }
            return .repository(Snapshot(
                status: status, branches: branches, remotes: remotes, changes: changes, operation: operation, stash: stash))
        } catch {
            return .failed(error)
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
            if remotes != snapshot.remotes { remotes = snapshot.remotes }
            hasUpstream = snapshot.status.upstream != nil
            ahead = snapshot.status.ahead
            behind = snapshot.status.behind
            if stash != snapshot.stash { stash = snapshot.stash }
            if operation != snapshot.operation { adopt(snapshot.operation) }
            if changes != snapshot.changes { changes = snapshot.changes }
        case .noGit:
            isGitAvailable = false
            isRepository = false
        case .notRepository:
            isRepository = false
            branch = nil
            headCommit = nil
            branches = []
            remotes = []
            hasUpstream = false
            ahead = 0
            behind = 0
            stash = nil
            if operation != nil { adopt(nil) }
            changes = []
        case .failed(let error):
            lastError = Failure(title: "Could not read the repository", error: error)
        }
    }

    /// Takes in what git is in the middle of. A merge's prepared message goes into an empty message field; when the
    /// merge is over, the message leaves with it unless it was changed.
    private func adopt(_ newOperation: GitOperation?) {
        if let message = newOperation?.message, trimmedMessage.isEmpty {
            commitMessage = message
            mergeMessage = message
        } else if newOperation == nil, let mergeMessage {
            if commitMessage == mergeMessage { commitMessage = "" }
            self.mergeMessage = nil
        }
        operation = newOperation
    }

    // MARK: - Staging and discarding

    /// `git add -A -- <paths>`. A conflicted file that still has git's conflict markers is asked about first: staging
    /// marks its conflict resolved, markers and all.
    func stage(_ changes: [Change]) {
        guard !changes.isEmpty, !isBusy else { return }
        Task {
            guard await confirmStagingConflictMarkers(in: changes) else { return }
            perform("Could not stage " + Self.naming(changes), ["add", "-A", "--"] + changes.map(\.relativePath))
        }
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

    /// `git add -A`, asking first about conflicted files that still have conflict markers.
    func stageAll() {
        guard !isBusy else { return }
        Task {
            guard await confirmStagingConflictMarkers(in: conflictedChanges) else { return }
            perform("Could not stage the changes", ["add", "-A"])
        }
    }

    /// True when none of the conflicted files among `changes` still has conflict markers, or the user stages them anyway.
    private func confirmStagingConflictMarkers(in changes: [Change]) async -> Bool {
        let conflicted = changes.filter(\.isConflicted)
        guard !conflicted.isEmpty else { return true }
        let marked = await Task.detached(priority: .userInitiated) {
            conflicted.filter { change in
                guard case .text(let snapshot) = TextFile.read(change.path) else { return false }
                return ConflictMarkers.present(in: snapshot.text)
            }
        }.value
        guard !marked.isEmpty else { return true }
        let one = marked.count == 1
        return await Self.ask(
            one ? "Stage “\(marked[0].name)” with its conflict markers?" : "Stage \(marked.count) files with conflict markers?",
            (one ? "The file still has" : "They still have")
                + " the lines git marked the conflict with (<<<<<<< and >>>>>>>). Staging marks the conflict resolved, and a commit would keep those lines.",
            button: "Stage")
    }

    /// Discard Changes… and Discard All Changes…, asked first. Conflicted files are left out: Take Mine or Take Theirs
    /// resolves them.
    func discardAfterAsking(_ changes: [Change]) {
        let discarding = changes.filter { $0.unstaged != nil && !$0.isConflicted }
        guard !discarding.isEmpty, !isBusy else { return }
        Task {
            let question = Self.discardQuestion(discarding)
            guard await Self.ask(question.title, question.message, button: question.button) else { return }
            discard(discarding)
        }
    }

    /// What Discard says it does. A tracked file goes back to its staged version, or to the last commit's when nothing
    /// is staged, and a copy of it as it is goes to the Trash first, as GitHub Desktop keeps discarded changes; a file
    /// git does not track goes to the Trash itself.
    private static func discardQuestion(_ changes: [Change]) -> (title: String, message: String, button: String) {
        let untracked = changes.filter(\.isUntracked)
        let tracked = changes.filter { !$0.isUntracked }
        if changes.count == 1, let change = changes.first {
            if change.isUntracked {
                return ("Move “\(change.name)” to the Trash?", "Git does not track the file, so discarding it moves it to the Trash.", "Move to Trash")
            }
            let version = change.staged != nil ? "its staged version" : "the version in the last commit"
            let message = change.unstaged == "D"
                ? "The deleted file comes back as \(change.staged != nil ? "it is staged" : "it was in the last commit")."
                : "The file goes back to \(version). A copy of it as it is now goes to the Trash."
            return ("Discard the changes to “\(change.name)”?", message, "Discard")
        }
        var sentences: [String] = []
        if !tracked.isEmpty {
            let versions = !tracked.contains { $0.staged != nil } ? "the versions in the last commit"
                : tracked.allSatisfy { $0.staged != nil } ? "their staged versions"
                : "their staged versions, or the last commit’s where nothing is staged"
            sentences.append("\(untracked.isEmpty ? "The files" : "Changed files") go back to \(versions), and copies of them as they are now go to the Trash.")
        }
        if !untracked.isEmpty {
            sentences.append(tracked.isEmpty ? "Git does not track them, so discarding moves them to the Trash." : "Files git does not track go to the Trash.")
        }
        return ("Discard the changes to \(changes.count) files?", sentences.joined(separator: " "), tracked.isEmpty ? "Move to Trash" : "Discard")
    }

    /// Untracked files go to the Trash; a copy of each tracked one goes there before `git restore --worktree` brings
    /// back the index's version (the last commit's when nothing is staged).
    private func discard(_ changes: [Change]) {
        let untracked = changes.filter(\.isUntracked).map(\.path)
        let tracked = changes.filter { !$0.isUntracked }
        run("Could not discard " + Self.naming(changes)) { [workspace] in
            for path in untracked { try FileManager.default.trashItem(at: URL(filePath: path), resultingItemURL: nil) }
            guard !tracked.isEmpty else { return }
            for change in tracked { try Self.trashCopy(of: change.path) }
            _ = try await Git.output(["restore", "--worktree", "--"] + tracked.map(\.relativePath), in: workspace)
        }
    }

    /// Puts a copy of the file at `path` into the Trash under its name; nothing for a path that is gone or no regular
    /// file (a symlink git restores as it was, a submodule).
    nonisolated private static func trashCopy(of path: String) throws {
        let files = FileManager.default
        let url = URL(filePath: path)
        guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { return }
        let folder = try files.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: url, create: true)
        defer { try? files.removeItem(at: folder) }
        let copy = folder.appending(path: url.lastPathComponent)
        try files.copyItem(at: url, to: copy)
        try files.trashItem(at: copy, resultingItemURL: nil)
    }

    // MARK: - Conflicts

    /// Take Mine, Take Theirs: each conflicted file becomes that side's version and is staged (`git checkout --ours` or
    /// `--theirs`, then `git add`), or is removed (`git rm`) where that side deleted it. A copy of the file as it was
    /// goes to the Trash first, with whatever resolving was begun by hand. Mine is the branch's side: git's "ours" in a
    /// merge, its "theirs" in a rebase, which replays the branch's commits onto what comes in.
    func take(_ side: Side, _ changes: [Change]) {
        let conflicted = changes.filter(\.isConflicted)
        guard !conflicted.isEmpty else { return }
        let ours = (side == .mine) != (operation?.kind == .rebase)
        run("Could not resolve " + Self.naming(conflicted)) { [workspace] in
            for change in conflicted {
                try Self.trashCopy(of: change.path)
                if ours ? change.hasOurVersion : change.hasTheirVersion {
                    _ = try await Git.output(["checkout", ours ? "--ours" : "--theirs", "--", change.relativePath], in: workspace)
                    _ = try await Git.output(["add", "--", change.relativePath], in: workspace)
                } else {
                    _ = try await Git.output(["rm", "-q", "--", change.relativePath], in: workspace)
                }
            }
        }
    }

    /// Abort Merge… and Abort Rebase…, asked first: `git merge --abort` or `git rebase --abort` puts the branch and
    /// the files back as they were before it began.
    func abortAfterAsking() {
        guard let operation, !isBusy else { return }
        let merge = operation.kind == .merge
        Task {
            let confirmed = await Self.ask(
                merge ? "Abort the merge?" : "Abort the rebase?",
                merge
                    ? "The files go back to how they were before the merge, and the conflicts you resolved are lost."
                    : "“\(operation.branch ?? "The branch")” goes back to how it was before the rebase, and the conflicts you resolved are lost.",
                button: merge ? "Abort Merge" : "Abort Rebase")
            guard confirmed else { return }
            perform(merge ? "Could not abort the merge" : "Could not abort the rebase", [merge ? "merge" : "rebase", "--abort"])
        }
    }

    /// Continue: `git rebase --continue` commits the resolved files with the replayed commit's message and replays the
    /// next, which may stop for conflicts of its own.
    func continueRebase() {
        guard operation?.kind == .rebase, conflictedChanges.isEmpty else { return }
        run("Could not continue the rebase") { [workspace] in
            try await Self.allowingConflicts(in: workspace) { _ = try await Git.output(["rebase", "--continue"], in: workspace) }
        }
    }

    /// Runs `work`, a git command that may stop for conflicts (a pull, a rebase, a stash put back): stopping there is no
    /// failure, as the Conflicts list and the merge's bar show what to do.
    nonisolated private static func allowingConflicts(in workspace: String, _ work: () async throws -> Void) async throws {
        do {
            try await work()
        } catch {
            let unmerged = try? await Git.text(["diff", "--name-only", "--diff-filter=U"], in: workspace)
            if unmerged?.isEmpty == false { return }
            throw error
        }
    }

    // MARK: - Committing

    /// `git commit -m <message>`, after `git add -A` when `stagingAll`; during a merge, the merge's commit. The draft
    /// clears once it is in.
    func commit(stagingAll: Bool = false) {
        let message = trimmedMessage
        guard stagingAll ? canStageAllAndCommit : canCommit else { return }
        run(isMerging ? "Could not commit the merge" : "Could not commit", { [workspace] in
            if stagingAll { _ = try await Git.output(["add", "-A"], in: workspace) }
            _ = try await Git.output(["commit", "-m", message], in: workspace)
        }, then: { [self] in
            commitMessage = ""
            mergeMessage = nil
        })
    }

    // MARK: - Remotes

    /// `git fetch`.
    func fetch() {
        guard canFetch else { return }
        perform("Could not fetch", ["fetch"])
    }

    /// `git pull`, merging diverged history unless the user's git configuration says otherwise (`GitPull`); from the
    /// default remote's branch of the same name when the branch tracks nothing yet. Conflicts leave a merge (or a
    /// rebase) to finish, which the panel shows.
    func pull() {
        guard canPull, let branch else { return }
        let remote = hasUpstream ? nil : defaultRemote
        run("Could not pull") { [workspace] in
            let arguments = await GitPull.arguments(branch: branch, remote: remote, in: workspace)
            try await Self.allowingConflicts(in: workspace) { _ = try await Git.output(arguments, in: workspace) }
        }
    }

    /// `git push`; `-u <remote> <branch>` when the branch tracks nothing yet, which makes it track what it pushed. A
    /// push the remote refused because it has commits the branch lacks fetches them, so the header counts them, and
    /// the notice offers Pull.
    func push() {
        guard canPush, let branch else { return }
        let remote = hasUpstream ? nil : defaultRemote
        run("Could not push") { [workspace] in
            do {
                _ = try await Git.output(["push"] + (remote.map { ["-u", $0, branch] } ?? []), in: workspace)
            } catch let failure as Git.Failure where GitProblem(stderr: failure.stderr, status: failure.status).kind == .remoteAhead {
                _ = try? await Git.output(["fetch"], in: workspace)
                throw failure
            }
        }
    }

    /// What a failure's notice offers next.
    func perform(_ remedy: Remedy) {
        switch remedy {
        case .pull: pull()
        case .push: push()
        }
    }

    // MARK: - Branches

    /// `git switch <name>`. When git refuses because the switch would overwrite local changes, asks to stash them.
    func switchBranch(_ name: String) {
        guard name != branch, canSwitchBranch else { return }
        let from = branch
        run("Could not switch to “\(name)”", { [workspace] in _ = try await Git.output(["switch", name], in: workspace) }, handling: { [self] problem in
            guard case .changesOverwritten(let files) = problem.kind, let from else { return false }
            offerStash(from: from, to: name, files: files)
            return true
        })
    }

    /// Stash and Switch?: all the changes, untracked files with them, are set aside on `from` as Lantern's stash,
    /// which the panel offers to restore there (GitHub Desktop's "Leave my changes on …").
    private func offerStash(from: String, to target: String, files: [String]) {
        Task {
            let confirmed = await Self.ask(
                "Stash your changes and switch to “\(target)”?",
                "Your changes to \(GitProblem.naming(files)) would be overwritten by “\(target)”. Stashing sets all your changes aside on “\(from)”, and Restore brings them back there.",
                button: "Stash and Switch", destructive: false)
            guard confirmed else { return }
            run("Could not switch to “\(target)”") { [workspace] in
                _ = try await Git.output(["stash", "push", "--include-untracked", "-m", GitStash.message(switchingTo: target)], in: workspace)
                do {
                    _ = try await Git.output(["switch", target], in: workspace)
                } catch {
                    // The changes go back where they were.
                    if let stash = await GitStash.newest(on: from, in: workspace) {
                        _ = try? await Git.output(["stash", "pop", stash.reference], in: workspace)
                    }
                    throw error
                }
            }
        }
    }

    /// Restore: `git stash pop` of Lantern's stash on this branch. Changes that conflict with the branch as it is now
    /// become conflicts, and git keeps the stash.
    func restoreStash() {
        guard let branch = branch ?? operation?.branch, stash != nil else { return }
        run("Could not restore the stashed changes") { [workspace] in
            guard let stash = await GitStash.newest(on: branch, in: workspace) else { return }
            try await Self.allowingConflicts(in: workspace) { _ = try await Git.output(["stash", "pop", stash.reference], in: workspace) }
        }
    }

    /// Opens the New Branch sheet; an earlier failure leaves, so the sheet only ever shows its own.
    func beginNamingBranch() {
        guard canSwitchBranch else { return }
        lastError = nil
        isNamingBranch = true
    }

    /// `git switch -c <name>`: made from HEAD and checked out. The sheet closes once it exists.
    func createBranch(_ name: String) {
        perform("Could not create “\(name)”", ["switch", "-c", name], then: { [self] in isNamingBranch = false })
    }

    /// `git init` in the project folder.
    func initialize() {
        perform("Could not initialize a repository", ["init"])
    }

    // MARK: - Comparing

    /// Diffs HEAD's version of the file (`git show HEAD:<path>`, the empty text for a file HEAD lacks) against the
    /// work tree, off the main thread, then shows it in a sheet.
    func compare(_ change: Change) {
        Task { [workspace] in
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<[LineDiff.Hunk], Error> in
                do {
                    let base = change.isNewToHead
                        ? "" : String(decoding: try await Git.output(["show", "HEAD:\(change.originalPath ?? change.relativePath)"], in: workspace), as: UTF8.self)
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
            case .failure(let error): lastError = Failure(title: "Could not compare “\(change.name)”", error: error)
            }
        }
    }

    private struct UnsupportedFile: LocalizedError {
        let reason: UnsupportedReason
        var errorDescription: String? {
            switch reason {
            case .tooLarge: "The file is too large to show as text."
            case .binary: "The file is not a text file."
            case .directory: "The path is a folder."
            case .unreadable(let message): message
            }
        }
    }

    // MARK: - Running

    /// Runs one git command as an action.
    private func perform(
        _ failureTitle: String, _ arguments: [String], handling handler: (@MainActor (GitProblem) -> Bool)? = nil,
        then completion: (@MainActor @Sendable () -> Void)? = nil
    ) {
        run(failureTitle, { [workspace] in _ = try await Git.output(arguments, in: workspace) }, handling: handler, then: completion)
    }

    /// Runs `work` off the main thread as the one action under way; a refresh follows either way. Its failure becomes
    /// `lastError`, in plain words, unless `handler` takes the problem git reported in hand.
    private func run(
        _ failureTitle: String, _ work: @escaping @Sendable () async throws -> Void,
        handling handler: (@MainActor (GitProblem) -> Bool)? = nil, then completion: (@MainActor @Sendable () -> Void)? = nil
    ) {
        guard !isBusy else { return }
        isBusy = true
        lastError = nil
        Task {
            let error = await Task.detached(priority: .userInitiated) { () -> (any Error)? in
                do {
                    try await work()
                    return nil
                } catch {
                    return error
                }
            }.value
            if let error {
                let problem = (error as? Git.Failure).map { GitProblem(stderr: $0.stderr, status: $0.status) }
                let handled = problem.map { handler?($0) ?? false } ?? false
                if !handled { lastError = Failure(title: failureTitle, error: error) }
            } else {
                completion?()
            }
            isBusy = false
            refresh()
        }
    }

    /// Asks before an action, in a sheet on the key window (an alert of its own while no window is key): `button` does
    /// it, Cancel (Esc) does not. A destructive button is red and has no Return key.
    private static func ask(_ title: String, _ message: String, button: String, destructive: Bool = true) async -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: button)
        alert.buttons[0].hasDestructiveAction = destructive
        alert.addButton(withTitle: "Cancel")
        let response = if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            await alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
        return response == .alertFirstButtonReturn
    }
}

extension GitRepository.Failure {
    /// A git failure in `GitProblem`'s words, with git's text for the tooltip and the next step it calls for; any
    /// other error in its own.
    init(title: String, error: any Error) {
        guard let failure = error as? Git.Failure else {
            self.init(title: title, message: error.localizedDescription)
            return
        }
        let problem = GitProblem(stderr: failure.stderr, status: failure.status)
        let remedy: GitRepository.Remedy? = switch problem.kind {
        case .remoteAhead: .pull
        case .noRemoteBranch: .push
        default: nil
        }
        self.init(title: title, message: problem.message, details: failure.stderr, remedy: remedy)
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
