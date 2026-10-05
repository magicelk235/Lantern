import AppKit

/// The Services menu entries for folders, declared under `NSServices` in `Resources/Info.plist`: in the
/// Finder's context menu (and Services menu), "Open in omp IDE" adds the folder as a project and brings its window
/// forward; "New omp Session" does that and starts omp in it. macOS launches the app for either when it is not running.
@MainActor
final class FinderServices: NSObject {
    private let app: AppState

    init(app: AppState) {
        self.app = app
    }

    /// `NSMessage` `openProject`.
    @objc(openProject:userData:error:)
    func openProject(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        for folder in Self.folders(on: pasteboard) {
            app.addProject(folder)
            app.showProject(AppState.normalized(folder))
        }
    }

    /// `NSMessage` `newSession`. Right after a launch the app is still connecting to ompd; the session is asked for once
    /// it is connected (10 s at most, then the usual "Could not start a session" alert says why).
    @objc(newSession:userData:error:)
    func newSession(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let folders = Self.folders(on: pasteboard)
        guard !folders.isEmpty else { return }
        for folder in folders {
            app.addProject(folder)
            app.showProject(AppState.normalized(folder))
        }
        Task {
            await app.waitUntilConnected()
            for folder in folders { app.newSession(in: folder) }
        }
    }

    /// The folders the Finder put on the pasteboard (file URLs; anything that is not a folder is left out).
    private static func folders(on pasteboard: NSPasteboard) -> [String] {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.compactMap { url in
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { return nil }
            return url.standardizedFileURL.path(percentEncoded: false)
        }
    }
}
