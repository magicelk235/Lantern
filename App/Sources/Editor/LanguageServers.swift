import Foundation
import IDELanguageModel
import os

/// The editor's language servers, independent of omp: one process per project folder and server kind,
/// started for the first editor of a file it takes and shut down (`shutdown`, then `exit`) when the last of those
/// editors closes and when the app quits. Servers run in the login shell's environment, captured once, and are found on
/// its `PATH`; a kind whose program is not installed has no server, which the status bar says quietly. A server that
/// fails to start or ends by itself stays that way until its editors close.
@MainActor @Observable
final class LanguageServers {
    struct Key: Hashable {
        /// The project folder: the server's workspace root and working directory.
        let root: String
        let kind: LanguageServerKind
    }

    enum Status: Equatable {
        case starting
        case running(name: String)
        /// No program for the kind was found (its names, for the note).
        case unavailable(programs: [String])
        /// It could not start, or ended by itself: why.
        case failed(String)
    }

    /// Each server's state, for the status bar.
    private(set) var statuses: [Key: Status] = [:]

    /// The documents of one server and what it is up to.
    private final class Entry {
        var documents: [LanguageDocument] = []
        var server: LanguageServer?
        var features: ServerFeatures?
    }

    @ObservationIgnored private var entries: [Key: Entry] = [:]
    @ObservationIgnored private var environment: Task<[String: String], Never>?
    /// Servers shutting down, which quitting waits for.
    @ObservationIgnored private var stopping: [ObjectIdentifier: Task<Void, Never>] = [:]

    /// An editor of a file its kind takes opened: it gets the server, which starts when it is the first.
    func attach(_ document: LanguageDocument) {
        if let entry = entries[document.key] {
            entry.documents.append(document)
            if let server = entry.server, let features = entry.features { document.connect(server, features) }
            return
        }
        let entry = Entry()
        entry.documents = [document]
        entries[document.key] = entry
        statuses[document.key] = .starting
        Task { await start(document.key, entry) }
    }

    /// The editor closed (it said `didClose` already); the server shuts down when it was the last.
    func detach(_ document: LanguageDocument) {
        guard let entry = entries[document.key], let index = entry.documents.firstIndex(where: { $0 === document }) else { return }
        entry.documents.remove(at: index)
        guard entry.documents.isEmpty else { return }
        entries[document.key] = nil
        statuses[document.key] = nil
        if let server = entry.server { stop(server) }
    }

    /// Shuts every server down (quitting), waiting at most `limit`: a server still running after that is left to the
    /// end of its stdin, which every server takes as the end of the session.
    func shutdownAll(within limit: Duration) async {
        for (key, entry) in entries {
            entries[key] = nil
            statuses[key] = nil
            if let server = entry.server { stop(server) }
        }
        let shutdowns = Array(stopping.values)
        guard !shutdowns.isEmpty else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let pending = OSAllocatedUnfairLock<CheckedContinuation<Void, Never>?>(initialState: continuation)
            Task {
                for shutdown in shutdowns { await shutdown.value }
                pending.withLock { $0.take() }?.resume()
            }
            Task {
                try? await Task.sleep(for: limit)
                pending.withLock { $0.take() }?.resume()
            }
        }
    }

    private func start(_ key: Key, _ entry: Entry) async {
        let environment = await loginEnvironment()
        let command = await Task.detached(priority: .userInitiated) {
            LanguageServerLocator(environment: environment).command(for: key.kind)
        }.value
        guard entries[key] === entry else { return }
        guard let command else {
            statuses[key] = .unavailable(programs: key.kind.programNames)
            return
        }
        let server = LanguageServer(command: command, environment: environment, root: key.root)
        entry.server = server
        do {
            let features = try await server.start()
            guard entries[key] === entry else { return }
            entry.features = features
            statuses[key] = .running(name: features.name)
            listen(to: server, key, entry)
            for document in entry.documents { document.connect(server, features) }
        } catch {
            guard entries[key] === entry else { return }
            entry.server = nil
            statuses[key] = .failed("\(command.name) \(error)")
        }
    }

    /// Routes the server's diagnostics to the editors of their file, and takes note when it ends by itself.
    private func listen(to server: LanguageServer, _ key: Key, _ entry: Entry) {
        Task { [weak self] in
            for await event in server.events {
                guard let self, entries[key] === entry else { return }
                switch event {
                case .diagnostics(let published):
                    for document in entry.documents where document.path == published.path {
                        document.publish(published)
                    }
                case .exited(let reason):
                    entry.server = nil
                    entry.features = nil
                    statuses[key] = .failed(reason)
                    for document in entry.documents { document.disconnect() }
                }
            }
        }
    }

    private func stop(_ server: LanguageServer) {
        let id = ObjectIdentifier(server)
        stopping[id] = Task {
            await server.shutdown()
            stopping[id] = nil
        }
    }

    /// The login shell's environment, captured the first time a server starts.
    private func loginEnvironment() async -> [String: String] {
        if let environment { return await environment.value }
        let capture = Task.detached(priority: .userInitiated) { await LoginShellEnvironment.capture() }
        environment = capture
        return await capture.value
    }
}
