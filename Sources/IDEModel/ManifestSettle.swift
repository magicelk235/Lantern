import Foundation
import IDEProtocol

/// What restarting ompd now would interrupt, read from the session manifest it keeps (`$APP_SUPPORT/sessions.json`):
/// how omp IDE judges an ompd it cannot ask, an older one that refuses its protocol (`version_mismatch`)
/// and runs until launchd restarts it.
public enum ManifestSettle: Equatable, Sendable {
    /// No session's omp is being started or resumed or works a turn: each is idle, paused, closed, needs attention or
    /// was interrupted. Also when there is no manifest.
    case settled
    /// The omp of these sessions is being started or resumed, or works a turn, in the manifest's order: a restart stops
    /// it and the restarted ompd resumes it.
    case unsettled([SessionKey])
    /// The manifest does not decode (the reason): what runs is unknown.
    case unreadable(String)

    /// Judges a manifest's contents; nil: there is no manifest. Older manifests decode (`SessionManifest`).
    public init(manifest data: Data?) {
        guard let data else {
            self = .settled
            return
        }
        let manifest: SessionManifest
        do {
            manifest = try IDECoding.decoder().decode(SessionManifest.self, from: data)
        } catch {
            self = .unreadable(String(describing: error))
            return
        }
        let unsettled = manifest.sessions.filter { Self.interrupts($0.status) }.map(\.sessionKey)
        self = unsettled.isEmpty ? .settled : .unsettled(unsettled)
    }

    /// Reads the manifest at `url` (`AppSupportPaths.manifest`).
    public init(contentsOf url: URL) {
        do {
            self.init(manifest: try Data(contentsOf: url))
        } catch CocoaError.fileReadNoSuchFile {
            self.init(manifest: nil)
        } catch {
            self = .unreadable(error.localizedDescription)
        }
    }

    /// omp is being started or resumed, or works a turn: an ompd restart stops it partway. Unlike `isSettled` (ompd's
    /// own judgement, which waits for the omp it is about to resume), `interrupted` counts as settled: that omp died,
    /// nothing of it runs, and the restarted ompd resumes it as the old one would have.
    private static func interrupts(_ status: SessionStatus) -> Bool {
        switch status {
        case .starting, .resuming, .busy: true
        case .idle, .paused, .closed, .needsAttention, .interrupted: false
        }
    }
}

/// Follows the manifest as ompd rewrites it. ompd replaces the file by atomic rename, so the watch is on its folder: a
/// vnode source for entries added, removed or renamed there. `changed` gets a fresh `ManifestSettle` after each such
/// change, on the main actor; other files of the folder come and go too, so a reading may repeat the one before.
/// Watching stops when the watch is released.
public final class ManifestWatch: Sendable {
    private let source: any DispatchSourceFileSystemObject

    /// Nil when the manifest's folder cannot be opened.
    public init?(manifest url: URL, changed: @escaping @MainActor @Sendable (ManifestSettle) -> Void) {
        let folder = open(url.deletingLastPathComponent().path(percentEncoded: false), O_EVTONLY)
        guard folder >= 0 else { return nil }
        source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: folder, eventMask: .write, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated { changed(ManifestSettle(contentsOf: url)) }
        }
        source.setCancelHandler { close(folder) }
        source.resume()
    }

    deinit {
        source.cancel()
    }
}
