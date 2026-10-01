import Darwin
import Foundation
import IDEProtocol

/// Keeps `SessionManifestEntry.installedOmpVersion` current: the version of the omp at the path each running
/// session is pinned to (`launch.ompPath`) — told by every spawn, which reads it anyway, read again when an app connects,
/// and when the file changes on disk. Each such path is watched instead of polled: a vnode watch on the path itself (for
/// Homebrew, the `bin/omp` link `brew upgrade` re-points) and on the file it resolves to (which an upgrade replaces or
/// removes); a burst of changes is read once, `settle` after the last. A pinned path that is gone counts as the omp a
/// new session would get, which is what the session's next spawn runs instead.
actor OmpInstallations {
    private let manifest: ManifestPublisher
    /// The omp a new session gets (`OmpBinary.locate` as the daemon is configured).
    private let locate: @Sendable () throws -> String
    private let persistenceFailed: @Sendable (any Error) -> Void
    private let settle: Duration
    /// The vnode watches of each pinned path; replaced at every `refresh`.
    private var watches: [String: Watch] = [:]
    /// A `refresh` waiting out `settle` after a change on disk.
    private var pendingRefresh: Task<Void, Never>?

    /// The vnode sources of one path, cancelled (closing their descriptors) once the watch is let go.
    private final class Watch {
        let sources: [any DispatchSourceFileSystemObject]

        init(_ sources: [any DispatchSourceFileSystemObject]) {
            self.sources = sources
        }

        deinit {
            for source in sources { source.cancel() }
        }
    }

    init(
        manifest: ManifestPublisher, locate: @escaping @Sendable () throws -> String,
        persistenceFailed: @escaping @Sendable (any Error) -> Void, settle: Duration = .seconds(1)
    ) {
        self.manifest = manifest
        self.locate = locate
        self.persistenceFailed = persistenceFailed
        self.settle = settle
    }

    /// A spawn found `version` at `path`: every session pinned to `path` sees it as installed, and `path` is watched.
    func spawned(_ version: String, at path: String) async {
        await record([path: version])
        if watches[path] == nil { watches[path] = arm(path) }
    }

    /// Reads the version at every path a running session is pinned to and watches those paths (an app connected, or a
    /// watched file changed).
    func refresh() async {
        let paths = Set(await manifest.sessions.filter(Self.runs).map(\.launch.ompPath))
        let locate = locate
        let versions = await withTaskGroup(of: (String, String?).self) { group in
            for path in paths {
                group.addTask { (path, await Self.installedVersion(at: path, locate: locate)) }
            }
            var versions: [String: String] = [:]
            for await (path, version) in group {
                if let version { versions[path] = version }
            }
            return versions
        }
        await record(versions)
        watches = Dictionary(uniqueKeysWithValues: paths.map { ($0, arm($0)) })
    }

    /// omp runs for the session, started by ompd (an adopted omp runs whatever its terminal ran).
    private static func runs(_ entry: SessionManifestEntry) -> Bool {
        !entry.adopted && [.starting, .resuming, .idle, .busy, .paused].contains(entry.status)
    }

    /// What `path` runs now: its own version, or — gone — the version of the omp a new session gets.
    private static func installedVersion(at path: String, locate: @Sendable () throws -> String) async -> String? {
        let omp = OmpBinary.isUsable(path) ? path : try? locate()
        guard let omp else { return nil }
        return try? await OmpBinary.version(at: omp, timeout: .seconds(10))
    }

    private func record(_ versions: [String: String]) async {
        guard !versions.isEmpty else { return }
        do {
            try await manifest.update { manifest in
                for index in manifest.sessions.indices {
                    guard let version = versions[manifest.sessions[index].launch.ompPath] else { continue }
                    manifest.sessions[index].installedOmpVersion = version
                }
            }
        } catch {
            persistenceFailed(error)
        }
    }

    /// Watches `path` (the link itself when it is one) and the file it resolves to for writes, replacement and removal.
    private func arm(_ path: String) -> Watch {
        var files = [(path, O_EVTONLY | O_SYMLINK)]
        if let resolved = realpath(path, nil) {
            let target = String(cString: resolved)
            free(resolved)
            if target != path { files.append((target, O_EVTONLY)) }
        }
        return Watch(files.compactMap { file, flags in
            let fd = open(file, flags)
            guard fd >= 0 else { return nil }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename, .revoke], queue: .global(qos: .utility))
            source.setEventHandler { [weak self] in
                Task { await self?.changed() }
            }
            source.setCancelHandler { close(fd) }
            source.resume()
            return source
        })
    }

    /// A watched file changed: read the versions again once the change settled.
    private func changed() {
        pendingRefresh?.cancel()
        let settle = settle
        pendingRefresh = Task {
            try? await Task.sleep(for: settle)
            guard !Task.isCancelled else { return }
            await self.refresh()
        }
    }
}
