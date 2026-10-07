import Foundation
@testable import IDEEditorModel
import Testing

/// A bare remote with one commit on `main` (conflict.txt, notes.txt) and clones of it, each with its own identity.
private final class Scratch: Sendable {
    let folder: TempFolder
    var remote: String { folder.file("remote.git") }

    init() async throws {
        folder = try TempFolder()
        try await git(["init", "-q", "--bare", "-b", "main", remote], in: folder.path)
        let seed = try await clone("seed")
        try await commit(["conflict.txt": "line 1\nshared\n", "notes.txt": "notes\n"], in: seed, "First")
        try await git(["push", "-q", "origin", "main"], in: seed)
    }

    func clone(_ name: String) async throws -> String {
        try await git(["clone", "-q", remote, name], in: folder.path)
        let path = folder.file(name)
        try await git(["config", "user.name", name], in: path)
        try await git(["config", "user.email", "\(name)@example.com"], in: path)
        return path
    }

    /// Writes the files (an empty text deletes one) and commits them all.
    func commit(_ files: [String: String], in clone: String, _ message: String) async throws {
        for (name, text) in files {
            let path = clone + "/" + name
            if text.isEmpty { try FileManager.default.removeItem(atPath: path) } else { try Data(text.utf8).write(to: URL(filePath: path)) }
        }
        try await git(["add", "-A"], in: clone)
        try await git(["commit", "-q", "-m", message], in: clone)
    }

    /// Two clones whose `main` diverged: `theirs` pushed a commit `mine` lacks, and `mine` made one of its own.
    func diverged(theirs: [String: String], mine: [String: String]) async throws -> (mine: String, theirs: String) {
        let other = try await clone("theirs")
        let local = try await clone("mine")
        try await commit(theirs, in: other, "Theirs")
        try await git(["push", "-q"], in: other)
        try await commit(mine, in: local, "Mine")
        return (local, other)
    }
}

@discardableResult
private func git(_ arguments: [String], in directory: String) async throws -> String {
    try await Git.text(arguments, in: directory)
}

/// The failure of a git command that is meant to fail.
private func failure(_ arguments: [String], in directory: String) async -> Git.Failure? {
    do {
        try await git(arguments, in: directory)
        return nil
    } catch {
        return error as? Git.Failure
    }
}

private func parents(of revision: String, in directory: String) async throws -> Int {
    try await git(["rev-list", "--parents", "-n", "1", revision], in: directory).split(separator: " ").count - 1
}

private func status(_ directory: String) async throws -> GitStatus {
    GitStatus.parse(try await Git.output(["status", "--porcelain=v2", "-z", "--branch"], in: directory))
}

private func operation(_ directory: String) async throws -> GitOperation? {
    await GitOperation.read(gitDirectory: try await git(["rev-parse", "--absolute-git-dir"], in: directory), in: directory)
}

@Suite(.enabled(if: Git.executable != nil, "git is not installed"), .timeLimit(.minutes(1)))
struct GitWorkflowTests {
    // MARK: - Pull

    @Test func pullMergesDivergedHistoryWhenGitIsNotToldHow() async throws {
        let scratch = try await Scratch()
        let (mine, _) = try await scratch.diverged(theirs: ["theirs.txt": "theirs\n"], mine: ["mine.txt": "mine\n"])
        try #require(await !GitPull.reconcilingIsConfigured(for: "main", in: mine), "this Mac's git configuration sets pull.rebase or pull.ff")
        // What Pull ran before: git 2.27 and later refuse to pick between merging and rebasing.
        let refused = await failure(["pull", "--no-edit"], in: mine)
        #expect(refused?.stderr.contains("Need to specify how to reconcile divergent branches") == true)

        let arguments = await GitPull.arguments(branch: "main", in: mine)
        #expect(arguments == ["pull", "--no-edit", "--no-rebase"])
        try await git(arguments, in: mine)
        #expect(try await parents(of: "HEAD", in: mine) == 2)
        let after = try await status(mine)
        #expect(after.ahead == 2 && after.behind == 0)
        #expect(try await operation(mine) == nil)
    }

    @Test func pullFollowsTheRebaseTheConfigurationAsksFor() async throws {
        let scratch = try await Scratch()
        let (mine, _) = try await scratch.diverged(theirs: ["theirs.txt": "theirs\n"], mine: ["mine.txt": "mine\n"])
        try await git(["config", "branch.main.rebase", "true"], in: mine)
        #expect(await GitPull.arguments(branch: "main", in: mine) == ["pull", "--no-edit"])
        try await git(["config", "--unset", "branch.main.rebase"], in: mine)
        try await git(["config", "pull.rebase", "true"], in: mine)
        let arguments = await GitPull.arguments(branch: "main", in: mine)
        #expect(arguments == ["pull", "--no-edit"])
        try await git(arguments, in: mine)
        // Rebased: one line of history, with the upstream under the local commit.
        #expect(try await parents(of: "HEAD", in: mine) == 1)
        try await git(["merge-base", "--is-ancestor", "origin/main", "HEAD"], in: mine)
        #expect(try await status(mine).ahead == 1)
    }

    @Test func pullOnABranchWithoutUpstreamNamesTheRemotesBranch() async throws {
        let scratch = try await Scratch()
        let mine = try await scratch.clone("mine")
        try await git(["switch", "-q", "-c", "topic"], in: mine)
        let arguments = await GitPull.arguments(branch: "topic", remote: "origin", in: mine)
        #expect(arguments.suffix(2) == ["origin", "topic"])
        let refused = try #require(await failure(arguments, in: mine))
        let problem = GitProblem(stderr: refused.stderr, status: refused.status)
        #expect(problem.kind == .noRemoteBranch("topic"))
        #expect(problem.message == "The remote has no branch “topic” yet. Push to publish it.")
    }

    @Test func fastForwardOnlyRefusesDivergedHistoryInPlainWords() async throws {
        let scratch = try await Scratch()
        let (mine, _) = try await scratch.diverged(theirs: ["theirs.txt": "theirs\n"], mine: ["mine.txt": "mine\n"])
        try await git(["config", "pull.ff", "only"], in: mine)
        let arguments = await GitPull.arguments(branch: "main", in: mine)
        // `--no-rebase` would override `pull.ff = only` and merge.
        #expect(arguments == ["pull", "--no-edit"])
        let refused = try #require(await failure(arguments, in: mine))
        #expect(GitProblem(stderr: refused.stderr, status: refused.status).kind == .cannotFastForward)
        #expect(try await parents(of: "HEAD", in: mine) == 1)
    }

    @Test func pullMergesWhenTheConfigurationOnlySaysWhetherToFastForward() async throws {
        let scratch = try await Scratch()
        let (mine, _) = try await scratch.diverged(theirs: ["theirs.txt": "theirs\n"], mine: ["mine.txt": "mine\n"])
        try await git(["config", "pull.ff", "false"], in: mine)
        try await git(await GitPull.arguments(branch: "main", in: mine), in: mine)
        #expect(try await parents(of: "HEAD", in: mine) == 2)
    }

    // MARK: - Merge and rebase state

    @Test func aConflictingPullLeavesAMergeToResolveAndCommit() async throws {
        let scratch = try await Scratch()
        let (mine, _) = try await scratch.diverged(
            theirs: ["conflict.txt": "line 1\ntheirs\n"], mine: ["conflict.txt": "line 1\nmine\n"])
        try #require(await !GitPull.reconcilingIsConfigured(for: "main", in: mine), "this Mac's git configuration sets pull.rebase or pull.ff")
        // git prints the conflict on stdout and exits 1: nothing on stderr says what happened.
        let stopped = try #require(await failure(await GitPull.arguments(branch: "main", in: mine), in: mine))
        #expect(stopped.status == 1)

        let merge = try #require(try await operation(mine))
        #expect(merge.kind == .merge)
        #expect(merge.incoming == "origin/main")
        #expect(merge.branch == nil)
        // git names the remote by its location without `.git`.
        #expect(merge.message == "Merge branch 'main' of \(scratch.remote.dropLast(4))")
        let conflicted = try await status(mine).entries.filter(\.isConflicted)
        #expect(conflicted.map(\.path) == ["conflict.txt"])
        #expect(conflicted.first?.hasOurVersion == true && conflicted.first?.hasTheirVersion == true)
        let file = try String(contentsOfFile: mine + "/conflict.txt", encoding: .utf8)
        #expect(ConflictMarkers.present(in: file))

        // Take Theirs, then Commit Merge with git's message.
        try await git(["checkout", "--theirs", "--", "conflict.txt"], in: mine)
        try await git(["add", "--", "conflict.txt"], in: mine)
        #expect(try await status(mine).entries.contains(where: \.isConflicted) == false)
        try await git(["commit", "-q", "-m", merge.message ?? ""], in: mine)
        #expect(try await operation(mine) == nil)
        #expect(try await parents(of: "HEAD", in: mine) == 2)
        #expect(try await git(["log", "-1", "--format=%B"], in: mine) == merge.message)
        #expect(try String(contentsOfFile: mine + "/conflict.txt", encoding: .utf8) == "line 1\ntheirs\n")
    }

    @Test func abortingAMergePutsTheBranchBack() async throws {
        let scratch = try await Scratch()
        let (mine, _) = try await scratch.diverged(
            theirs: ["conflict.txt": "line 1\ntheirs\n"], mine: ["conflict.txt": "line 1\nmine\n"])
        try await git(["config", "pull.rebase", "false"], in: mine)
        _ = await failure(await GitPull.arguments(branch: "main", in: mine), in: mine)
        #expect(try await operation(mine)?.kind == .merge)
        let refused = try #require(await failure(["pull", "--no-edit"], in: mine))
        #expect(GitProblem(stderr: refused.stderr, status: refused.status).kind == .unresolvedConflicts)
        try await git(["merge", "--abort"], in: mine)
        #expect(try await operation(mine) == nil)
        #expect(try String(contentsOfFile: mine + "/conflict.txt", encoding: .utf8) == "line 1\nmine\n")
    }

    @Test func aMergeWithItsConflictsResolvedStillWaitsForItsCommit() async throws {
        let scratch = try await Scratch()
        let (mine, _) = try await scratch.diverged(
            theirs: ["conflict.txt": "line 1\ntheirs\n"], mine: ["conflict.txt": "line 1\nmine\n"])
        try await git(["config", "pull.rebase", "false"], in: mine)
        _ = await failure(await GitPull.arguments(branch: "main", in: mine), in: mine)
        // Take Mine leaves nothing staged: the index matches HEAD, and the merge still needs its commit.
        try await git(["checkout", "--ours", "--", "conflict.txt"], in: mine)
        try await git(["add", "--", "conflict.txt"], in: mine)
        #expect(try await status(mine).entries.isEmpty)
        #expect(try await operation(mine)?.kind == .merge)
        let refused = try #require(await failure(["pull", "--no-edit"], in: mine))
        #expect(GitProblem(stderr: refused.stderr, status: refused.status).kind == .unfinishedOperation)
        try await git(["commit", "-q", "-m", "Merge"], in: mine)
        #expect(try await parents(of: "HEAD", in: mine) == 2)
    }

    @Test func aRebaseThatStopsSaysWhichBranchAndOntoWhat() async throws {
        let scratch = try await Scratch()
        let (mine, _) = try await scratch.diverged(
            theirs: ["conflict.txt": "line 1\ntheirs\n"], mine: ["conflict.txt": "line 1\nmine\n"])
        try await git(["config", "pull.rebase", "true"], in: mine)
        _ = await failure(await GitPull.arguments(branch: "main", in: mine), in: mine)
        let rebase = try #require(try await operation(mine))
        #expect(rebase == GitOperation(kind: .rebase, incoming: "origin/main", branch: "main"))
        #expect(try await status(mine).head == nil)
        // In a rebase git's "theirs" is the commit being replayed: the local one.
        try await git(["checkout", "--theirs", "--", "conflict.txt"], in: mine)
        #expect(try String(contentsOfFile: mine + "/conflict.txt", encoding: .utf8) == "line 1\nmine\n")
        try await git(["add", "--", "conflict.txt"], in: mine)
        // Continues without an editor (`GIT_EDITOR=true`), keeping the commit's message.
        try await git(["rebase", "--continue"], in: mine)
        #expect(try await operation(mine) == nil)
        #expect(try await git(["log", "-1", "--format=%s"], in: mine) == "Mine")
        try await git(["merge-base", "--is-ancestor", "origin/main", "HEAD"], in: mine)
    }

    @Test func aSideThatDeletedTheFileHasNoVersionOfIt() async throws {
        let scratch = try await Scratch()
        let (mine, _) = try await scratch.diverged(theirs: ["conflict.txt": "line 1\ntheirs\n"], mine: ["conflict.txt": ""])
        try await git(["config", "pull.rebase", "false"], in: mine)
        _ = await failure(await GitPull.arguments(branch: "main", in: mine), in: mine)
        let entry = try #require(try await status(mine).entries.first { $0.path == "conflict.txt" })
        #expect(entry.isConflicted)
        #expect(!entry.hasOurVersion && entry.hasTheirVersion)
    }

    // MARK: - Failures in plain words

    @Test func aRejectedPushIsTheRemoteBeingAhead() async throws {
        let scratch = try await Scratch()
        let (mine, _) = try await scratch.diverged(theirs: ["theirs.txt": "theirs\n"], mine: ["mine.txt": "mine\n"])
        let unfetched = try #require(await failure(["push"], in: mine))
        #expect(unfetched.stderr.contains("(fetch first)"))
        let problem = GitProblem(stderr: unfetched.stderr, status: unfetched.status)
        #expect(problem.kind == .remoteAhead)
        #expect(problem.message == "The remote has commits you don’t have. Pull them, then push again.")
        try await git(["fetch", "-q"], in: mine)
        let fetched = try #require(await failure(["push"], in: mine))
        #expect(fetched.stderr.contains("(non-fast-forward)"))
        #expect(GitProblem(stderr: fetched.stderr, status: fetched.status).kind == .remoteAhead)
    }

    @Test func switchingOverConflictingChangesNamesTheFilesAndAStashCarriesThem() async throws {
        let scratch = try await Scratch()
        let mine = try await scratch.clone("mine")
        try await git(["switch", "-q", "-c", "other"], in: mine)
        try await scratch.commit(["conflict.txt": "line 1\nother\n", "new.txt": "other's\n"], in: mine, "Other")
        try await git(["switch", "-q", "main"], in: mine)
        try Data("line 1\nedited\n".utf8).write(to: URL(filePath: mine + "/conflict.txt"))
        let refused = try #require(await failure(["switch", "other"], in: mine))
        let problem = GitProblem(stderr: refused.stderr, status: refused.status)
        #expect(problem.kind == .changesOverwritten(files: ["conflict.txt"]))
        #expect(problem.message == "Your changes to “conflict.txt” would be overwritten. Commit or stash them first.")

        try Data("mine\n".utf8).write(to: URL(filePath: mine + "/new.txt"))
        try await git(["checkout", "-q", "--", "conflict.txt"], in: mine)
        let untracked = try #require(await failure(["switch", "other"], in: mine))
        #expect(GitProblem(stderr: untracked.stderr, status: untracked.status).kind == .changesOverwritten(files: ["new.txt"]))

        // Stash and Switch, then Restore back on main.
        try Data("line 1\nedited\n".utf8).write(to: URL(filePath: mine + "/conflict.txt"))
        try await git(["stash", "push", "-q", "--include-untracked", "-m", GitStash.message(switchingTo: "other")], in: mine)
        // Someone stashes something else on main meanwhile, in a terminal: Lantern's stash is no longer the newest.
        try Data("notes edited\n".utf8).write(to: URL(filePath: mine + "/notes.txt"))
        try await git(["stash", "push", "-q", "-m", "someone else's"], in: mine)
        try await git(["switch", "-q", "other"], in: mine)
        #expect(await GitStash.newest(on: "other", in: mine) == nil)
        try await git(["switch", "-q", "main"], in: mine)
        let stash = try #require(await GitStash.newest(on: "main", in: mine))
        #expect(stash.index == 1)
        try await git(["stash", "pop", "-q", stash.reference], in: mine)
        #expect(try String(contentsOfFile: mine + "/conflict.txt", encoding: .utf8) == "line 1\nedited\n")
        #expect(try String(contentsOfFile: mine + "/new.txt", encoding: .utf8) == "mine\n")
        #expect(await GitStash.newest(on: "main", in: mine) == nil)
    }

    @Test func otherCommonFailuresInPlainWords() async throws {
        let scratch = try await Scratch()
        let mine = try await scratch.clone("mine")
        func problem(_ arguments: [String], in directory: String) async throws -> GitProblem {
            let refused = try #require(await failure(arguments, in: directory))
            return GitProblem(stderr: refused.stderr, status: refused.status)
        }

        let exists = try await problem(["switch", "-c", "main"], in: mine)
        #expect(exists == GitProblem(stderr: "fatal: a branch named 'main' already exists"))
        #expect(exists.kind == .branchExists("main") && exists.message == "A branch named “main” already exists.")

        let alone = scratch.folder.file("alone")
        try FileManager.default.createDirectory(atPath: alone, withIntermediateDirectories: true)
        try await git(["init", "-q", "-b", "main"], in: alone)
        try await git(["-c", "user.name=a", "-c", "user.email=a@example.com", "commit", "-q", "--allow-empty", "-m", "First"], in: alone)
        let noRemote = try await problem(["push", "-u", "origin", "main"], in: alone)
        #expect(noRemote.kind == .noSuchRemote("origin"))
        #expect(noRemote.message == "The repository has no remote named “origin”.")
        try await git(["remote", "add", "gone", scratch.folder.file("gone.git")], in: alone)
        #expect(try await problem(["fetch", "gone"], in: alone).message == "There’s no repository at “\(scratch.folder.file("gone.git"))”.")

        try Data().write(to: URL(filePath: mine + "/.git/index.lock"))
        try Data("edited\n".utf8).write(to: URL(filePath: mine + "/notes.txt"))
        #expect(try await problem(["add", "-A"], in: mine).kind == .repositoryLocked)
        try FileManager.default.removeItem(atPath: mine + "/.git/index.lock")

        let unknown = try await problem(["rev-parse", "--verify", "nowhere"], in: mine)
        #expect(unknown.kind == .other)
        #expect(unknown.message == "Needed a single revision.")
        #expect(GitProblem(stderr: "", status: 3).message == "Git stopped with status 3.")
        #expect(GitProblem(stderr: "To /tmp/x.git\nhint: something\nerror: it broke").message == "It broke.")
    }

    // MARK: - Names and markers

    @Test func branchNamesFollowGitsRulesInFindersWords() {
        let existing = ["main", "feature", "release/1.0"]
        #expect(GitBranchName.problem("feature/greeting", existing: ["main"]) == nil)
        #expect(GitBranchName.problem("feature/greeting bad name", existing: existing) == "Branch names can’t contain spaces.")
        #expect(GitBranchName.problem("main", existing: existing) == "A branch named “main” already exists.")
        #expect(GitBranchName.problem("Main", existing: existing) == "A branch named “main” already exists.")
        #expect(GitBranchName.problem("feature/x", existing: existing) == "A branch named “feature” exists, so a name can’t start with “feature/”.")
        #expect(GitBranchName.problem("release", existing: existing) == "Branches named “release/…” exist, so “release” can’t be a branch too.")
        #expect(GitBranchName.problem("a~1", existing: []) == "Branch names can’t contain “~”.")
        #expect(GitBranchName.problem("a:b", existing: []) == "Branch names can’t contain “:”.")
        #expect(GitBranchName.problem("a..b", existing: []) == "Branch names can’t contain “..”.")
        #expect(GitBranchName.problem("a@{1}", existing: []) == "Branch names can’t contain “@{”.")
        #expect(GitBranchName.problem("-x", existing: []) == "Branch names can’t begin with “-”.")
        #expect(GitBranchName.problem("x/", existing: []) == "Branch names can’t begin or end with “/”.")
        #expect(GitBranchName.problem("x.", existing: []) == "Branch names can’t end with “.”.")
        #expect(GitBranchName.problem("a/.b", existing: []) == "No part of a branch name can begin with “.”.")
        #expect(GitBranchName.problem("a.lock/b", existing: []) == "No part of a branch name can end with “.lock”.")
        #expect(GitBranchName.problem("HEAD", existing: []) == "The name “HEAD” is reserved by git.")
    }

    @Test func branchNamesGitRefusesAreRefusedHereToo() async throws {
        let folder = try TempFolder()
        try await git(["init", "-q", "-b", "main"], in: folder.path)
        for name in ["a b", "a~1", "a^", "a:b", "a?", "a*", "a[b", "a\\b", "a..b", "a@{b", "a//b", "-a", "/a", "a/", "a.", ".a", "a/.b", "a.lock"] {
            #expect(GitBranchName.problem(name, existing: []) != nil, "\(name)")
            #expect(await failure(["check-ref-format", "--branch", name], in: folder.path) != nil, "\(name)")
        }
        // git makes a branch named "@", which then reads as HEAD in every command.
        #expect(GitBranchName.problem("@", existing: []) == "The name “@” is reserved by git.")
        for name in ["feature/greeting", "fix-1.2", "José", "a@b", "a.b/c"] {
            #expect(GitBranchName.problem(name, existing: []) == nil, "\(name)")
            #expect(await failure(["check-ref-format", "--branch", name], in: folder.path) == nil, "\(name)")
        }
    }

    @Test func conflictMarkersAreAnOpeningLineAndALaterClosingOne() {
        #expect(ConflictMarkers.present(in: "a\n<<<<<<< HEAD\nmine\n=======\ntheirs\n>>>>>>> origin/main\nb\n"))
        #expect(ConflictMarkers.present(in: "<<<<<<<\r\nmine\r\n>>>>>>>\r\n"))
        #expect(!ConflictMarkers.present(in: "resolved\n"))
        #expect(!ConflictMarkers.present(in: ">>>>>>> before\n<<<<<<< after\n"))
        #expect(!ConflictMarkers.present(in: "<<<<<<<< eight\n>>>>>>>> eight\n"))
        #expect(!ConflictMarkers.present(in: "// <<<<<<< quoted\n// >>>>>>> quoted\n"))
    }

    @Test func gitsMergeMessageLosesItsCommentLines() {
        #expect(GitOperation.withoutComments("Merge branch 'main' of /tmp/r\n\n# Conflicts:\n#\tconflict.txt\n") == "Merge branch 'main' of /tmp/r")
        #expect(GitOperation.withoutComments("Merge\n\nBody\n# comment\n") == "Merge\n\nBody")
    }
}
