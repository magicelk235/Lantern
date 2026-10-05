import CoreSpotlight
import CryptoKit
import IDEModel
import IDEProtocol
import UniformTypeIdentifiers
import os

/// The projects' omp sessions in Spotlight: each saved session file is a searchable item titled like Open
/// Session… lists it (its title, else its first message), with the first message as its text. Choosing one in Spotlight
/// opens it as Open Session… does (`continue(_:)`). The index is rebuilt when the projects change or a session gets a
/// new file or title (busy/idle flips don't count), two seconds after the last change; items never expire on their
/// own (Spotlight drops app items after 30 days otherwise) and go with the project or the file. Every item sits in one
/// domain named after this app's data folder (`AppSupportPaths`), and a rebuild replaces only that domain: a build run
/// with its own `OMPD_HOME` never removes the installed app's items, which share the bundle identifier's index.
@MainActor
final class SpotlightSessions {
    private let app: AppState
    private let index = CSSearchableIndex.default()
    /// What the index was last built from.
    private var indexed: Signature?
    private var pending: Task<Void, Never>?
    private let domain = "sessions." + SHA256.hash(data: Data(AppSupportPaths.standard.root.path(percentEncoded: false).utf8))
        .map { String(format: "%02x", $0) }.joined()

    private struct Signature: Equatable {
        var projects: [String]
        var sessions: [String: String]
    }

    init(app: AppState) {
        self.app = app
    }

    func start() {
        observe()
    }

    private func observe() {
        let signature = withObservationTracking {
            Signature(
                projects: app.projects,
                sessions: Dictionary(
                    app.connection.sessions.compactMap { entry in entry.sessionFile.map { ($0, entry.title ?? "") } },
                    uniquingKeysWith: { first, _ in first }))
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observe() }
        }
        guard signature != indexed else { return }
        indexed = signature
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await self?.rebuild(projects: signature.projects)
        }
    }

    private func rebuild(projects: [String]) async {
        var items: [CSSearchableItem] = []
        for project in projects {
            for file in await app.sessionFiles(of: project) {
                items.append(Self.item(file, in: project, domain: domain))
            }
            guard !Task.isCancelled else { return }
        }
        let index = index
        index.deleteSearchableItems(withDomainIdentifiers: [domain]) { error in
            if let error {
                appLog.error("Spotlight: removing the old session items failed: \(String(describing: error), privacy: .public)")
            }
            index.indexSearchableItems(items) { error in
                if let error {
                    appLog.error("Spotlight: indexing the sessions failed: \(String(describing: error), privacy: .public)")
                }
            }
        }
    }

    private static func item(_ file: SessionFileInfo, in project: String, domain: String) -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: .text)
        attributes.title = file.displayTitle
        attributes.displayName = file.displayTitle
        attributes.contentDescription = "omp session in \(AppState.projectName(project))"
        attributes.textContent = [file.title, file.firstMessage].compactMap(\.self).joined(separator: "\n")
        attributes.contentCreationDate = file.created
        attributes.contentModificationDate = file.modified
        attributes.keywords = ["omp", "session", AppState.projectName(project)]
        let item = CSSearchableItem(
            uniqueIdentifier: identifier(project: project, path: file.path), domainIdentifier: domain, attributeSet: attributes)
        item.expirationDate = .distantFuture
        return item
    }

    /// The item's identifier: its project and session file, which is all `continue(_:)` needs even in an app Spotlight
    /// just launched.
    static func identifier(project: String, path: String) -> String {
        String(decoding: (try? JSONEncoder().encode([project, path])) ?? Data(), as: UTF8.self)
    }

    static func decode(_ identifier: String) -> (project: String, path: String)? {
        guard let parts = try? JSONDecoder().decode([String].self, from: Data(identifier.utf8)), parts.count == 2 else { return nil }
        return (parts[0], parts[1])
    }

    /// A session chosen in Spotlight: its project's window comes forward and the session opens there (its tab, a
    /// resume of the stopped session, or a new session resuming the file). False for any other activity.
    func `continue`(_ activity: NSUserActivity) -> Bool {
        guard activity.activityType == CSSearchableItemActionType,
              let identifier = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
              let (project, path) = Self.decode(identifier)
        else { return false }
        app.addProject(project)
        app.showProject(project)
        Task {
            await app.waitUntilConnected()
            app.openSessionFile(path, in: project)
        }
        return true
    }
}
