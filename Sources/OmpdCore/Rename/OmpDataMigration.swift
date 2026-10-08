import Darwin
import Foundation
import IDEProtocol

/// The renamed project folder's paths in the two forms omp writes: canonical (`realpath`, which names session folders)
/// and omp's own (`OmpPaths.ompCwd`: `/tmp/x` for `/private/tmp/x`, written into headers, history and memory).
struct ProjectPaths: Codable, Sendable, Equatable {
    var canonical: FolderMove
    var omp: FolderMove

    init(canonical: FolderMove, omp: FolderMove) {
        self.canonical = canonical
        self.omp = omp
    }

    /// Where `path`, in either form, is inside the old folder: "" for the folder itself, "/<rest>" inside it.
    func suffix(of path: String) -> String? {
        for from in [canonical.from, omp.from] {
            guard let moved = FolderMove(from: from, to: "").moved(path) else { continue }
            return moved
        }
        return nil
    }

    /// `path` after the move, in the form it was written in; nil outside the folder.
    func moved(_ path: String) -> String? {
        canonical.moved(path) ?? omp.moved(path)
    }
}

/// Moves what omp keeps under a project folder's path, in one omp agent directory, to the folder's new path: the
/// session files (each file's header names the new cwd; its subagents and backups go along), the Mnemopi memory banks,
/// the prompt history's cwds, the terminals' `--continue` records, the records of session files kept inside the folder,
/// and the cached status line. For the folder and every folder in it omp has data for. Each step is idempotent and
/// carries on past what fails, which `Outcome.problems` names: run again after a crash, it finishes what is left.
struct OmpDataMigration {
    let paths: ProjectPaths
    let storage: OmpAgentStorage
    /// `mnemopi.bank` and `mnemopi.dbPath` as omp reads its settings: where the banks are and how they are named.
    var bankBase: String?
    var databasePath: String?

    struct Outcome: Equatable {
        /// Session files moved, old path to new.
        var sessionFiles: [String: String] = [:]
        /// What stayed under the old path, a sentence each.
        var problems: [String] = []
    }

    private var fileManager: FileManager { .default }
    private var projectName: String { (paths.canonical.from as NSString).lastPathComponent }

    /// The old cwds (as written) of the folder and of folders in it that omp has data for: the session headers of its
    /// session folders and the prompt history. What the memory step looks for banks of.
    func knownCwds() -> [String] {
        var cwds = [paths.omp.from, paths.canonical.from]
        for directory in sessionDirectories(for: paths.canonical.from) {
            for file in sessionFiles(in: directory) {
                if let cwd = try? SessionFileHeader.read(file)?.string("cwd"), paths.suffix(of: cwd) != nil { cwds.append(cwd) }
            }
        }
        if let database = try? SQLiteFile(path: storage.historyDB) {
            for table in ["history", "session_recaps"] where (try? database.hasTable(table)) == true {
                for from in Set([paths.canonical.from, paths.omp.from]) {
                    cwds += (try? database.rows(
                        "SELECT DISTINCT cwd FROM \(table) WHERE cwd = ?1 OR substr(cwd, 1, length(?1) + 1) = ?1 || '/'", [from])) ?? []
                }
            }
        }
        var seen = Set<String>()
        return cwds.filter { seen.insert($0).inserted }
    }

    func run(cwds: [String]) -> Outcome {
        var outcome = Outcome()
        moveMemory(cwds: cwds, &outcome)
        moveSessions(&outcome)
        rewriteHistory(&outcome)
        rewriteTerminalRecords(&outcome)
        rewriteSessionFileRecords(&outcome)
        rewriteStatusCache()
        return outcome
    }

    // MARK: - Session files

    /// Every session file of the folder or of a folder in it goes to the session folder of its cwd's new path, with its
    /// artifacts folder (subagent transcripts) and backups; its header then names the new cwd, its old path joins
    /// `previousSessionFiles` (as omp's own `moveTo` records a move), and parent paths follow. A file found already in
    /// place with the old cwd (a run cut short) only gets its header rewritten.
    private func moveSessions(_ outcome: inout Outcome) {
        let directories = sessionDirectories(for: paths.canonical.from) + sessionDirectories(for: paths.canonical.to)
        var failed: [String] = []
        for directory in Set(directories).sorted() {
            for file in sessionFiles(in: directory) {
                guard let header = try? SessionFileHeader.read(file), let cwd = header.string("cwd"),
                      let suffix = paths.suffix(of: cwd)
                else { continue }
                let name = (file as NSString).lastPathComponent
                let original = (storage.sessionDirectory(canonicalCwd: paths.canonical.from + suffix) as NSString).appendingPathComponent(name)
                let target = storage.sessionDirectory(canonicalCwd: OmpAgentStorage.canonical(paths.canonical.to + suffix))
                let destination = (target as NSString).appendingPathComponent(name)
                do {
                    let moved = destination == file ? file : try moveSession(file, to: destination)
                    outcome.sessionFiles[original] = moved
                    try rewriteHeaders(of: moved, movedFrom: original)
                } catch {
                    failed.append("“\(name)” (\(Self.reason(error)))")
                }
            }
            // A session folder left empty goes, as omp's own migrations leave none behind (the Finder's view settings
            // do not count).
            let left = (try? fileManager.contentsOfDirectory(atPath: directory)) ?? ["?"]
            if left.allSatisfy({ $0 == ".DS_Store" }) {
                for name in left { unlink((directory as NSString).appendingPathComponent(name)) }
                rmdir(directory)
            }
        }
        if !failed.isEmpty {
            let sessions = failed.count == 1 ? "An omp session" : "\(failed.count) omp sessions"
            outcome.problems.append("\(sessions) of “\(projectName)” stayed in the old folder’s list: \(failed.joined(separator: ", ")).")
        }
    }

    /// The session folders of `canonicalFolder` and of folders in it: its own, and those whose name continues it (a
    /// folder in it, or another folder whose name starts the same way; their headers tell them apart).
    private func sessionDirectories(for canonicalFolder: String) -> [String] {
        guard let names = try? fileManager.contentsOfDirectory(atPath: storage.sessions) else { return [] }
        let own = OmpPaths.sessionDirectoryName(
            canonicalCwd: canonicalFolder, home: storage.home, temporaryDirectory: storage.temporaryDirectory)
        // `--<absolute>--`: a folder inside is `--<absolute>-<name>--`.
        let stem = own.hasPrefix("--") && own.hasSuffix("--") && own.count > 4 ? String(own.dropLast(2)) : own
        return names.filter { $0 == own || $0.hasPrefix(stem + "-") }.map { (storage.sessions as NSString).appendingPathComponent($0) }
    }

    /// The top-level `*.jsonl` files of a session folder (subagent transcripts are in each session's own folder).
    private func sessionFiles(in directory: String) -> [String] {
        ((try? fileManager.contentsOfDirectory(atPath: directory)) ?? [])
            .filter { $0.hasSuffix(".jsonl") && !$0.hasPrefix(".") }
            .sorted()
            .map { (directory as NSString).appendingPathComponent($0) }
    }

    /// Moves a session file, its artifacts folder and its backups (`<file>.<stamp>.bak`), refusing before moving
    /// anything when one of them is taken at the destination. Returns where the file is now: where it was when the
    /// destination is the same folder by another name (a rename that only changes case, on a volume that ignores case).
    private func moveSession(_ file: String, to destination: String) throws -> String {
        let directory = (file as NSString).deletingLastPathComponent
        let target = (destination as NSString).deletingLastPathComponent
        if Self.isSameItem(directory, target) { return file }
        let name = (file as NSString).lastPathComponent
        var moves = [(file, destination)]
        let artifacts = String(file.dropLast(".jsonl".count))
        if fileManager.fileExists(atPath: artifacts) { moves.append((artifacts, String(destination.dropLast(".jsonl".count)))) }
        for backup in ((try? fileManager.contentsOfDirectory(atPath: directory)) ?? []) where backup.hasPrefix(name + ".") && backup.hasSuffix(".bak") {
            moves.append(((directory as NSString).appendingPathComponent(backup), (target as NSString).appendingPathComponent(backup)))
        }
        for (_, to) in moves where fileManager.fileExists(atPath: to) {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: to])
        }
        try fileManager.createDirectory(atPath: target, withIntermediateDirectories: true)
        for (from, to) in moves {
            guard Darwin.rename(from, to) == 0 else { throw StorageError.system(operation: "rename", path: from, code: errno) }
        }
        return destination
    }

    /// The header of a moved session file and of its subagents' transcripts: the new cwd, parent paths that moved,
    /// workspace folders inside the project; the main file records where it was.
    private func rewriteHeaders(of file: String, movedFrom original: String) throws {
        let mapping = SessionPathMapping(original: original, current: file, paths: paths)
        try SessionFileHeader.rewrite(file) { header in
            mapping.apply(to: &header)
            if original != file {
                let previous = header.strings("previousSessionFiles") ?? []
                if !previous.contains(original) { header.set("previousSessionFiles", previous + [original]) }
            }
        }
        let artifacts = String(file.dropLast(".jsonl".count))
        guard let walker = fileManager.enumerator(atPath: artifacts) else { return }
        for case let relative as String in walker where relative.hasSuffix(".jsonl") {
            try SessionFileHeader.rewrite((artifacts as NSString).appendingPathComponent(relative)) { mapping.apply(to: &$0) }
        }
    }

    // MARK: - Memory

    /// Each Mnemopi bank of the old cwds is renamed to its new cwd's name (Mnemopi names a project's bank by its cwd's
    /// hash). A bank the new name already has stays as it is: two memories cannot be merged.
    private func moveMemory(cwds: [String], _ outcome: inout Outcome) {
        let banks = storage.memoryBanks(databasePath: databasePath)
        var seen = Set<String>()
        for cwd in cwds {
            guard let suffix = paths.suffix(of: cwd) else { continue }
            for move in [paths.omp, paths.canonical] {
                let old = OmpPaths.memoryBank(cwd: move.from + suffix, base: bankBase)
                let new = OmpPaths.memoryBank(cwd: move.to + suffix, base: bankBase)
                guard old != new, seen.insert(old).inserted else { continue }
                let source = (banks as NSString).appendingPathComponent(old)
                guard fileManager.fileExists(atPath: source) else { continue }
                let destination = (banks as NSString).appendingPathComponent(new)
                let folder = ((move.to + suffix) as NSString).lastPathComponent
                if fileManager.fileExists(atPath: destination) {
                    outcome.problems.append("omp’s memory of “\(projectName)” stayed under the old name: “\(folder)” already has memory of its own.")
                } else if Darwin.rename(source, destination) != 0 {
                    outcome.problems.append("omp’s memory of “\(projectName)” couldn’t be moved: \(String(cString: strerror(errno))).")
                }
            }
        }
    }

    // MARK: - Prompt history

    /// The cwd of each prompt typed in the folder or in a folder in it, and of each session recap, in one transaction.
    private func rewriteHistory(_ outcome: inout Outcome) {
        do {
            guard let database = try SQLiteFile(path: storage.historyDB) else { return }
            let tables = try ["history", "session_recaps"].filter { try database.hasTable($0) }
            try database.transaction {
                for move in Set([paths.canonical, paths.omp]) {
                    for table in tables {
                        try database.run(
                            "UPDATE \(table) SET cwd = ?2 || substr(cwd, length(?1) + 1) WHERE cwd = ?1 OR substr(cwd, 1, length(?1) + 1) = ?1 || '/'",
                            [move.from, move.to])
                    }
                }
            }
        } catch {
            outcome.problems.append("omp’s prompt history still names “\(projectName)”: \(error).")
        }
    }

    // MARK: - Records

    /// `terminal-sessions/<tty>`: the cwd and session file `omp --continue` resumes in that terminal.
    private func rewriteTerminalRecords(_ outcome: inout Outcome) {
        for record in records(in: storage.terminalSessions) {
            guard let text = try? String(contentsOfFile: record, encoding: .utf8) else { continue }
            var lines = text.components(separatedBy: "\n")
            guard lines.count >= 2 else { continue }
            let session = lines[1]
            if let suffix = paths.suffix(of: lines[0]) {
                lines[0] = paths.moved(lines[0]) ?? lines[0]
                let folder = storage.sessionDirectory(canonicalCwd: paths.canonical.from + suffix)
                if (session as NSString).deletingLastPathComponent == folder {
                    lines[1] = (storage.sessionDirectory(canonicalCwd: OmpAgentStorage.canonical(paths.canonical.to + suffix)) as NSString)
                        .appendingPathComponent((session as NSString).lastPathComponent)
                }
            }
            if lines[1] == session, let moved = paths.moved(session) { lines[1] = moved }
            let rewritten = lines.joined(separator: "\n")
            guard rewritten != text else { continue }
            do {
                try StorageIO.writeAtomically(Data(rewritten.utf8), to: URL(filePath: record), mode: 0o644, durable: false)
            } catch {
                outcome.problems.append("A terminal’s “omp --continue” still resumes in “\(projectName)”: \(error).")
            }
        }
    }

    /// `custom-session-files/<hash>`: session files kept outside omp's session folders (a `--session-dir` inside the
    /// project), whose record is named by the file's path.
    private func rewriteSessionFileRecords(_ outcome: inout Outcome) {
        for record in records(in: storage.customSessionFiles) {
            guard let path = try? String(contentsOfFile: record, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
                  let moved = paths.moved(path)
            else { continue }
            let renamed = (storage.customSessionFiles as NSString).appendingPathComponent(OmpPaths.customSessionRecordName(sessionFile: moved))
            do {
                try StorageIO.writeAtomically(Data(moved.utf8), to: URL(filePath: renamed), mode: 0o644, durable: false)
                if renamed != record { unlink(record) }
            } catch {
                outcome.problems.append("omp’s record of a session file in “\(projectName)” couldn’t be moved: \(error).")
            }
        }
    }

    /// `cache/composer.db`: the status line omp draws at startup, per cwd. A row the new path has already wins. A cache:
    /// what fails is drawn afresh by omp.
    private func rewriteStatusCache() {
        guard let database = try? SQLiteFile(path: storage.composerDB), (try? database.hasTable("entries")) == true else { return }
        try? database.transaction {
            for move in Set([paths.canonical, paths.omp]) {
                let inside = "project = ?1 OR substr(project, 1, length(?1) + 1) = ?1 || '/'"
                try database.run("UPDATE OR IGNORE entries SET project = ?2 || substr(project, length(?1) + 1) WHERE \(inside)", [move.from, move.to])
                try database.run("DELETE FROM entries WHERE \(inside)", [move.from])
            }
        }
    }

    private func records(in directory: String) -> [String] {
        ((try? fileManager.contentsOfDirectory(atPath: directory)) ?? [])
            .filter { !$0.hasPrefix(".") }
            .map { (directory as NSString).appendingPathComponent($0) }
    }

    static func reason(_ error: any Error) -> String {
        if let error = error as? CocoaError, error.code == .fileWriteFileExists { return "one of the same name is already there" }
        if case .system(_, _, let code) = error as? StorageError { return String(cString: strerror(code)) }
        return "\(error)"
    }

    /// `a` and `b` name the same file or folder (the same device and inode).
    static func isSameItem(_ a: String, _ b: String) -> Bool {
        var first = stat()
        var second = stat()
        return stat(a, &first) == 0 && stat(b, &second) == 0 && first.st_dev == second.st_dev && first.st_ino == second.st_ino
    }
}

/// Where the paths a session header names went when its file moved from `original` to `current`: the file itself, its
/// subagents' transcripts, other sessions of its session folder (a fork's parent), paths inside the project.
private struct SessionPathMapping {
    let original: String
    let current: String
    let paths: ProjectPaths

    func moved(_ path: String) -> String? {
        if path == original { return current }
        let artifacts = FolderMove(from: String(original.dropLast(".jsonl".count)), to: String(current.dropLast(".jsonl".count)))
        if let inArtifacts = artifacts.moved(path) { return inArtifacts }
        let folder = (original as NSString).deletingLastPathComponent
        if original != current, (path as NSString).deletingLastPathComponent == folder {
            return ((current as NSString).deletingLastPathComponent as NSString).appendingPathComponent((path as NSString).lastPathComponent)
        }
        return paths.moved(path)
    }

    func apply(to header: inout JSONObjectLine) {
        if let cwd = header.string("cwd"), let moved = paths.moved(cwd) { header.set("cwd", moved) }
        if let parent = header.string("parentSession"), let moved = moved(parent), moved != parent { header.set("parentSession", moved) }
        if let directories = header.strings("additionalDirectories") {
            let moved = directories.map { paths.moved($0) ?? $0 }
            if moved != directories { header.set("additionalDirectories", moved) }
        }
    }
}
