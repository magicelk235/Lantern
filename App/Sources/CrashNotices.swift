import AppKit
import IDEModel

/// Crash reports macOS wrote for this app or the ompd in its bundle since the user last saw one (telemetry-free), looked
/// for at launch and whenever the app becomes active; the window shows the newest as one notice. Only the reports'
/// names, dates and headers are read (`CrashReport.Owner`: the app's bundle identifier, the ompd executable's UUIDs),
/// so another copy of Lantern or another program of the same name is not news here; nothing leaves the Mac. The newest
/// report seen is remembered in the defaults; on the very first look there is none, and reports from before then are
/// not news.
@MainActor @Observable
final class CrashNotices {
    /// Overrides `CrashReport.standardDirectory` (tests and smoke runs), with a last-seen date of its own.
    static let directoryEnvironmentKey = "LANTERN_DIAGNOSTIC_REPORTS"

    /// Reports newer than the last one seen, newest first.
    private(set) var unseen: [CrashReport] = []

    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let lastSeenKey: String
    /// Whose reports count.
    @ObservationIgnored private let owner: CrashReport.Owner
    @ObservationIgnored private var activation: (any NSObjectProtocol)?

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        if let overridden = environment[Self.directoryEnvironmentKey], !overridden.isEmpty {
            directory = URL(filePath: overridden, directoryHint: .isDirectory)
            lastSeenKey = "lastSeenCrashReport:\(directory.path(percentEncoded: false))"
        } else {
            directory = CrashReport.standardDirectory
            lastSeenKey = "lastSeenCrashReport"
        }
        owner = .app()
    }

    /// Looks now and each time the app becomes active. Idempotent.
    func start() {
        guard activation == nil else { return }
        look()
        activation = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.look() }
        }
    }

    /// The newest report seen: the notice goes until a newer one comes.
    func dismiss() {
        guard let newest = unseen.first else { return }
        UserDefaults.lantern.set(newest.date, forKey: lastSeenKey)
        unseen = []
    }

    /// Shows the newest report in the Finder (Console opens it from there), and counts the reports as seen.
    func showReport() {
        guard let newest = unseen.first else { return }
        NSWorkspace.shared.activateFileViewerSelecting([newest.url])
        dismiss()
    }

    private func look() {
        guard let lastSeen = UserDefaults.lantern.object(forKey: lastSeenKey) as? Date else {
            UserDefaults.lantern.set(Date(), forKey: lastSeenKey)
            return
        }
        let found = CrashReport.newer(than: lastSeen, in: directory, of: owner)
        if found != unseen { unseen = found }
    }
}
