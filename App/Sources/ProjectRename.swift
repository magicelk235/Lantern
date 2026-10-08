import AppKit
import Darwin
import IDEModel
import IDEState

/// Rename Project… and Locate Folder…: a project's folder gets a new name, and everything follows it. ompd stops the
/// project's sessions, renames the folder, moves what omp keeps under its path (sessions, memory, prompt history) and
/// resumes the sessions there (`project.rename`); the app's windows, tabs, editors (unsaved text and undo included),
/// navigators and terminals follow (`projectMoved`). The app's journal (`ProjectRenameJournal`) lets the next launch
/// settle a rename a crash or a quit cut short.
extension AppState {
    /// A named service a rename stops, in the folder of the sessions that recorded it.
    struct ServiceStop: Equatable {
        let name: String
        let workspace: String
    }

    /// Asks for the folder's new name, saying in the Finder's words what is wrong with one as it is typed; then, when
    /// that interrupts sessions or named services, asks once in the project's window; then renames. Refused while omp
    /// runs in the folder outside Lantern: ompd cannot stop it, and its session would not follow.
    func renameProject(_ project: String) {
        guard renaming == nil else { return }
        let current = Self.projectName(project)
        let parent = (project as NSString).deletingLastPathComponent
        guard let name = FileNamePrompt.ask(
            "Rename “\(current)”", message: "Enter a new name for the project’s folder:", button: "Rename",
            placeholder: current, initial: current,
            problem: { FileNamePrompt.problem(naming: $0, in: parent, renaming: project) }),
            name != current
        else { return }
        let move = FolderMove(from: project, to: (parent as NSString).appendingPathComponent(name))
        Task { await requestRename(move) }
    }

    private func requestRename(_ move: FolderMove) async {
        let folder = move.from
        if let pid = await Task.detached(priority: .userInitiated, operation: { ForeignOmp.running(in: folder) }).value {
            alert = AlertMessage(
                title: "“\(Self.projectName(move.from))” can’t be renamed while omp runs in it outside Lantern.",
                message: "Quit the omp you started in a terminal there (process \(pid)), then rename the project. That omp keeps "
                    + "its session under the folder’s current name, and its session would not follow the folder.")
            return
        }
        let services = await liveServices(in: move)
        var request = CloseRequest(action: .renameProject(move, services: services), project: move.from)
        request.sessions = connection.sessions.filter { move.contains($0.workspace) && $0.runsOmp }.map { entry in
            CloseRequest.EndingSession(title: sessionTitle(entry.sessionKey), working: entry.status == .busy, resumable: true)
        }
        if request.sessions.isEmpty && services.isEmpty {
            await renameFolder(move, stopping: [])
        } else {
            confirm(request)
        }
    }

    /// The named services running in the folder or in a folder inside it with sessions: a rename stops them, or they
    /// would run on under the old path, out of reach of the sessions that started them. omp's broker knows them by
    /// that path only: the agent starts them again in the renamed folder.
    private func liveServices(in move: FolderMove) async -> [ServiceStop] {
        var workspaces = [move.from]
        for workspace in connection.workspaces.map(\.path) where move.contains(workspace) && !workspaces.contains(workspace) {
            workspaces.append(workspace)
        }
        var stops: [ServiceStop] = []
        for workspace in workspaces {
            let services = (try? await connection.services(in: URL(filePath: workspace, directoryHint: .isDirectory))) ?? []
            stops += services.filter(\.isLive).map { ServiceStop(name: $0.name, workspace: workspace) }
        }
        return stops
    }

    /// Renames the folder through ompd. The editors of the folder write nothing meanwhile, and the app's journal is
    /// written first; once ompd answers, the app follows the folder and the journal goes. A refusal leaves everything as
    /// it was and says why in the Finder's words; what of omp's data could not follow is the renamed window's notice.
    func renameFolder(_ move: FolderMove, stopping services: [ServiceStop]) async {
        guard renaming == nil else { return }
        renaming = move
        defer { renaming = nil }
        editors.holdFolder(move.from)
        flushState()
        do {
            try ProjectRenameJournal(move).write(to: persistence.paths.projectRenameApp)
        } catch {
            editors.releaseFolder(move.from)
            alert = AlertMessage(
                title: "“\(Self.projectName(move.from))” couldn’t be renamed.",
                message: "Lantern could not note the rename down first: \(error.localizedDescription)")
            return
        }
        for service in services {
            _ = try? await connection.control(service: service.name, in: URL(filePath: service.workspace, directoryHint: .isDirectory), .stop)
        }
        do {
            let result = try await connection.renameProject(from: move.from, to: move.to)
            finishRename(FolderMove(from: move.from, to: result.workspace), notMoved: result.notMoved)
        } catch {
            await renameFailed(move, error: error)
        }
    }

    /// The folder is at `move.to`: the app follows it and its journal goes.
    private func finishRename(_ move: FolderMove, notMoved: [String]) {
        projectMoved(move)
        try? ProjectRenameJournal.remove(at: persistence.paths.projectRenameApp)
        renameNotice = notMoved.isEmpty ? nil : RenameNotice(project: move.to, notMoved: notMoved)
    }

    /// How long a rename whose answer never came (the connection dropped) is waited for before the next launch is left
    /// to settle it.
    private static let renameAnswerWait: Duration = .seconds(60)

    /// ompd refused, or its answer never came: the disk says whether the folder moved. ompd's refusal is final unless
    /// the folder moved before it failed; without an answer, ompd may still be at it, which its journal says.
    private func renameFailed(_ move: FolderMove, error: any Error) async {
        let journal = ProjectRenameJournal(move)
        var outcome = journal.outcome(daemonJournal: persistence.paths.projectRename)
        if error is DaemonError {
            if outcome == .undecided { outcome = .dropped }
        } else {
            let deadline = ContinuousClock.now + Self.renameAnswerWait
            while outcome == .undecided, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(500))
                outcome = journal.outcome(daemonJournal: persistence.paths.projectRename)
            }
        }
        switch outcome {
        case .moved(let moved):
            finishRename(moved, notMoved: [])
            alert = AlertMessage(
                title: "“\(Self.projectName(moved.to))” was renamed, but ompd ran into a problem",
                message: error.userMessage + " Its sessions resume once ompd has finished the rename, at the latest when it next starts.")
        case .dropped:
            try? ProjectRenameJournal.remove(at: persistence.paths.projectRenameApp)
            editors.releaseFolder(move.from)
            alert = AlertMessage(title: "“\(Self.projectName(move.from))” couldn’t be renamed.", message: error.userMessage)
        case .undecided:
            // The journal stays for the next launch.
            editors.releaseFolder(move.from)
            alert = AlertMessage(
                title: "Lantern can’t tell whether “\(Self.projectName(move.from))” was renamed",
                message: error.userMessage + " ompd finishes or undoes the rename when it next starts; Lantern follows it then.")
        }
    }

    /// Locate Folder…: the session's folder `move.from` is gone and the user found it at `move.to` (renamed or moved in
    /// the Finder). ompd moves what omp keeps under the old path there, with the folder's other sessions
    /// (`project.rename` without moving the folder), and the app's tabs and editors of the old folder follow. What could
    /// not follow is the window's notice; an ompd without the method changes nothing. Returns once ompd's list names
    /// the new folder for `sessionKey`, so a resume finds its moved session file.
    func followFolder(_ move: FolderMove, of sessionKey: SessionKey) async {
        guard move.from != move.to, renaming == nil else { return }
        renaming = move
        defer { renaming = nil }
        do {
            try? ProjectRenameJournal(move).write(to: persistence.paths.projectRenameApp)
            let result = try await connection.renameProject(from: move.from, to: move.to, moveFolder: false)
            finishRename(FolderMove(from: move.from, to: result.workspace), notMoved: result.notMoved)
            let deadline = ContinuousClock.now + .seconds(3)
            while entry(for: sessionKey).map({ $0.workspace != result.workspace }) == true, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
        } catch {
            try? ProjectRenameJournal.remove(at: persistence.paths.projectRenameApp)
            guard (error as? DaemonError)?.code != .unknownMethod else { return }
            renameNotice = RenameNotice(
                project: move.to,
                notMoved: ["omp’s sessions, memory and history stayed under “\(Self.projectName(move.from))”: \(error.userMessage)"])
        }
    }

    /// A rename the launch could not settle (ompd was still at it then): once ompd is in reach, the disk tells.
    func settleRenameLeftBehind() async {
        guard let journal = ProjectRenameJournal.read(at: persistence.paths.projectRenameApp) else { return }
        await waitUntilConnected(timeout: .seconds(30))
        guard renaming == nil, ProjectRenameJournal.read(at: persistence.paths.projectRenameApp) == journal else { return }
        switch journal.outcome(daemonJournal: persistence.paths.projectRename) {
        case .moved(let move): finishRename(move, notMoved: [])
        case .dropped: try? ProjectRenameJournal.remove(at: persistence.paths.projectRenameApp)
        case .undecided: break
        }
    }
}

/// omp started in a folder outside Lantern (in Terminal, say): ompd neither started it nor can stop it.
enum ForeignOmp {
    /// An omp whose working folder is `folder` or inside it and that no ompd started, directly or in one of Lantern's
    /// terminals; nil when none runs there. omp's own workers (`omp __omp_worker_…`) don't count.
    static func running(in folder: String) -> pid_t? {
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return nil }
        var pids = [pid_t](repeating: 0, count: Int(capacity) + 64)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard count > 0 else { return nil }
        for pid in pids.prefix(Int(count)) where pid > 0 && name(of: pid) == "omp" {
            guard let cwd = workingFolder(of: pid), cwd == folder || cwd.hasPrefix(folder + "/") else { continue }
            guard !isWorker(pid), !descends(pid, from: "ompd") else { continue }
            return pid
        }
        return nil
    }

    private static func name(of pid: pid_t) -> String? {
        var buffer = [UInt8](repeating: 0, count: 64)
        let length = buffer.withUnsafeMutableBytes { proc_name(pid, $0.baseAddress, UInt32($0.count)) }
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
    }

    private static func workingFolder(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        return withUnsafeBytes(of: info.pvi_cdir.vip_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    private static func parent(of pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return pid_t(info.pbi_ppid)
    }

    private static func descends(_ pid: pid_t, from ancestor: String) -> Bool {
        var current = pid
        for _ in 0..<32 {
            guard let parent = parent(of: current), parent > 1 else { return false }
            if name(of: parent) == ancestor { return true }
            current = parent
        }
        return false
    }

    /// omp runs its broker and embedders as `omp __omp_worker_<kind>`.
    private static func isWorker(_ pid: pid_t) -> Bool {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return false }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return false }
        return String(decoding: buffer.prefix(size), as: UTF8.self).contains("__omp_worker")
    }
}
