import Foundation
import IDEModel

/// The first prompt typed into each session, from its session file: what a session omp has not titled goes by
/// (`AppState.sessionTitle`). Files are read off the main thread, from their first 4 KiB (`SessionFileListing`), when
/// the sessions change in ompd's manifest or in what their omp runs, and only for sessions with neither a title nor a
/// known prompt; a file is read again only once its size or modification date moved. A file's first prompt never
/// changes once written.
@MainActor @Observable
final class SessionPrompts {
    /// The first prompt's first line, by session file.
    private(set) var prompts: [String: String] = [:]
    /// The session files looked at for a prompt at least once, with one found or not (or no file there yet): until
    /// then, an untitled session's title is not known (`AppState.tabTitles(in:)`).
    private(set) var looked: Set<String> = []
    /// The size and modification date of each file read without a prompt in it, by session file.
    @ObservationIgnored private var stamps: [String: FileStamp] = [:]
    /// The files to read next, once the read under way is done.
    @ObservationIgnored private var pending: [String]?
    @ObservationIgnored private var reading: Task<Void, Never>?

    /// How long a burst of manifest and runtime pushes settles before the files are looked at.
    private static let settle: Duration = .milliseconds(400)

    func prompt(forFile sessionFile: String?) -> String? {
        sessionFile.flatMap { prompts[$0] }
    }

    func hasLooked(atFile sessionFile: String) -> Bool {
        looked.contains(sessionFile)
    }

    /// Follows `connection`'s sessions from now on.
    func follow(_ connection: DaemonConnection) {
        let (wanted, listed) = withObservationTracking {
            files(of: connection)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.follow(connection) }
        }
        // Sessions ompd no longer lists take their prompts with them.
        if prompts.keys.contains(where: { !listed.contains($0) }) { prompts = prompts.filter { listed.contains($0.key) } }
        if !looked.isSubset(of: listed) { looked.formIntersection(listed) }
        stamps = stamps.filter { listed.contains($0.key) }
        if !wanted.isEmpty { schedule(wanted) }
    }

    /// The files of the sessions without a title or a known prompt, and every session's file. Looking at what the
    /// sessions' omp runs too while one is wanted, so each step an agent takes looks for its prompt again.
    private func files(of connection: DaemonConnection) -> (wanted: [String], listed: Set<String>) {
        var wanted: [String] = []
        var listed = Set<String>()
        for entry in connection.sessions {
            guard let file = entry.sessionFile else { continue }
            listed.insert(file)
            if entry.title?.isEmpty ?? true, prompts[file] == nil { wanted.append(file) }
        }
        if !wanted.isEmpty { _ = connection.runtimes }
        return (wanted, listed)
    }

    private func schedule(_ files: [String]) {
        pending = files
        guard reading == nil else { return }
        reading = Task { [weak self] in
            try? await Task.sleep(for: Self.settle)
            while let self, let files = self.pending {
                self.pending = nil
                await self.read(files)
            }
            self?.reading = nil
        }
    }

    private func read(_ files: [String]) async {
        let known = stamps
        let found = await Task.detached(priority: .utility) {
            files.map { file -> (file: String, stamp: FileStamp?, prompt: String?) in
                let url = URL(filePath: file)
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                // Not written yet (omp writes a new session's file with its first answer), or unchanged since it was read.
                guard let values else { return (file, nil, nil) }
                let stamp = FileStamp(modified: values.contentModificationDate, size: values.fileSize)
                guard known[file] != stamp else { return (file, stamp, nil) }
                return (file, stamp, SessionFileListing.info(file: url)?.promptTitle)
            }
        }.value
        for (file, stamp, prompt) in found {
            if let prompt {
                prompts[file] = prompt
                stamps[file] = nil
            } else {
                stamps[file] = stamp
            }
        }
        let seen = looked.union(found.map(\.file))
        if seen != looked { looked = seen }
    }
}

/// A file's size and modification date, which tell whether it changed since it was last read.
private struct FileStamp: Equatable, Sendable {
    let modified: Date?
    let size: Int?
}
