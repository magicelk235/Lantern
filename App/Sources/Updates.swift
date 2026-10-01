import Sparkle
import SwiftUI

/// App updates through Sparkle 2. The feed is the bundle's `SUFeedURL`, which a release build fills from
/// `SPARKLE_FEED_URL` (`scripts/release.sh` with `FEED_URL`), with `SUPublicEDKey` to verify what it downloads. A build
/// without a feed has no `Updates`: Sparkle is never started, so it never checks or prompts.
///
/// With a feed, Sparkle checks on its own schedule (it asks the user for permission on the second launch), downloads
/// an update in the background and installs it when the app quits (`SUAutomaticallyUpdate`). Quitting goes through
/// `applicationShouldTerminate` like any quit: ompd pauses the sessions and keeps running, and the new app's hello
/// upgrades it.
@MainActor @Observable
final class Updates {
    /// Whether a check can start now: false while one runs.
    private(set) var canCheckForUpdates = false

    private let controller: SPUStandardUpdaterController
    @ObservationIgnored private var canCheckObservation: NSKeyValueObservation?

    /// Starts Sparkle; nil when `bundle` names no feed.
    init?(bundle: Bundle = .main) {
        guard let feed = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String, !feed.isEmpty else { return nil }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        // Sparkle's updater lives on the main actor and changes the property there.
        canCheckObservation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            MainActor.assumeIsolated { self?.canCheckForUpdates = updater.canCheckForUpdates }
        }
    }

    /// Checks now and shows the result, whatever it is (Check for Updates…).
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}

/// Check for Updates… in the app menu, after About; absent from a build without a feed.
struct UpdateCommands: Commands {
    let updates: Updates?

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            if let updates {
                Button("Check for Updates…") { updates.checkForUpdates() }
                    .disabled(!updates.canCheckForUpdates)
            }
        }
    }
}
