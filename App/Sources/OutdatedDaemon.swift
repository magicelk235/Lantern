import AppKit
import IDEModel
import Observation
import SwiftUI

/// An ompd that refuses this app's protocol (`version_mismatch`) and does not move to the ompd installed with the app by
/// itself: one from before in-place upgrades existed, which runs until launchd restarts it. The app decides from the manifest
/// that ompd keeps (`ManifestSettle`): when no session's omp is being started, resumed or working a turn, launchd
/// restarts it at once (`DaemonAgent.kickstart()`); otherwise the window's notice asks, offering Restart Now (confirmed
/// first) and Restart When Idle, which restarts it the moment the manifest reads settled. While the notice shows it
/// follows the manifest. With `OMPD_HOME` set the ompd is the developer's: the notice says to restart it, and nothing
/// restarts the registered one. Once the app restarted ompd, one that still refuses it is left to the user until the app
/// connected again: restarts never loop.
@MainActor @Observable
final class OutdatedDaemon {
    enum Phase: Equatable {
        /// ompd answers this app, or nothing is decided yet.
        case none
        /// The notice asks; what a restart would interrupt, as the manifest says now.
        case outOfDate(ManifestSettle)
        /// Restart When Idle: ompd restarts the moment the manifest reads settled; what it says now.
        case waiting(ManifestSettle)
        /// launchd stops the old ompd and starts the installed one (`launchctl kickstart` runs).
        case restarting
    }

    private(set) var phase: Phase = .none
    /// Why the last restart failed; cleared by the next one and once the app connects.
    private(set) var failure: String?
    /// The app restarted ompd since it last connected: an ompd that still refuses it is not restarted again by itself.
    private(set) var restartedSinceConnected = false

    @ObservationIgnored private let connection: DaemonConnection
    @ObservationIgnored private let agent: DaemonAgent
    /// Follows the manifest while the notice shows.
    @ObservationIgnored private var watch: ManifestWatch?

    init(connection: DaemonConnection, agent: DaemonAgent) {
        self.connection = connection
        self.agent = agent
    }

    /// `OMPD_HOME`, when set: the ompd is the developer's to restart.
    var developerHome: String? {
        if case .external(let home) = agent.state { home } else { nil }
    }

    /// Follows the connection from now on.
    func start() {
        observe()
    }

    /// Restart When Idle: ompd restarts the moment the manifest reads settled (now, if it does).
    func restartWhenIdle() {
        guard developerHome == nil, case .outOfDate = phase else { return }
        guard watch != nil else {
            failure = "Lantern cannot watch \(connection.paths.manifest.path(percentEncoded: false))."
            return
        }
        let settle = ManifestSettle(contentsOf: connection.paths.manifest)
        if settle == .settled { restart() } else { phase = .waiting(settle) }
    }

    /// Restart Now, which the user confirmed: every running omp is stopped, the new ompd resumes it, and turns the
    /// restart interrupts follow the restore policy.
    func restartNow() {
        guard developerHome == nil else { return }
        switch phase {
        case .outOfDate, .waiting: restart()
        case .none, .restarting: break
        }
    }

    private func observe() {
        let status = withObservationTracking {
            connection.status
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observe() }
        }
        follow(status)
    }

    private func follow(_ status: DaemonConnection.Status) {
        switch status {
        case .connected:
            watch = nil
            if phase != .none { phase = .none }
            if failure != nil { failure = nil }
            if restartedSinceConnected { restartedSinceConnected = false }
        case .versionMismatch:
            if phase == .none { decide() }
        case .connecting, .daemonUnavailable:
            break
        }
    }

    /// A refusal while nothing is decided: launchd restarts ompd at once when that interrupts nothing, else the notice asks.
    private func decide() {
        if developerHome == nil, !restartedSinceConnected, ManifestSettle(contentsOf: connection.paths.manifest) == .settled {
            restart()
        } else {
            ask()
        }
    }

    private func ask() {
        let manifest = connection.paths.manifest
        // Watching before reading: a change in between would go unseen.
        watch = ManifestWatch(manifest: manifest) { [weak self] in self?.manifestChanged($0) }
        phase = .outOfDate(ManifestSettle(contentsOf: manifest))
    }

    private func manifestChanged(_ settle: ManifestSettle) {
        switch phase {
        case .outOfDate(let shown) where shown != settle: phase = .outOfDate(settle)
        case .waiting where settle == .settled: restart()
        case .waiting(let shown) where shown != settle: phase = .waiting(settle)
        case .none, .outOfDate, .waiting, .restarting: break
        }
    }

    private func restart() {
        watch = nil
        failure = nil
        restartedSinceConnected = true
        phase = .restarting
        Task {
            let failure = await agent.kickstart()
            // The app connected meanwhile: the new ompd answered.
            guard phase == .restarting else { return }
            if let failure {
                self.failure = failure
                ask()
            } else {
                // The connection's next attempt reaches the new ompd.
                phase = .none
            }
        }
    }
}

/// The window's notice about an ompd that refuses this app (`OutdatedDaemon`), while it does: Restart When Idle and
/// Restart Now… (asked first, in a sheet on the project's window), or for the developer's ompd (`OMPD_HOME`) only what
/// to do; a spinner while the restart waits for the sessions or runs. ompd's own words are its tooltip.
struct OutdatedDaemonBar: View {
    let app: AppState
    /// The window's project; empty for the window of no project.
    let project: String

    private var outdated: OutdatedDaemon { app.outdatedDaemon }

    var body: some View {
        switch outdated.phase {
        case .none:
            EmptyView()
        case .restarting:
            NoticeBar(
                systemImage: "arrow.clockwise", tint: .orange, title: "Restarting ompd",
                message: "launchd stops the old ompd and starts the one this version of Lantern comes with, which resumes the sessions.",
                inProgress: true)
        case .outOfDate(let settle):
            if case .versionMismatch(let refusal) = app.connection.status {
                NoticeBar(
                    systemImage: outdated.failure == nil ? "arrow.up.circle" : "exclamationmark.triangle",
                    tint: outdated.failure == nil ? .orange : .red, title: title, message: "\(reason) \(Self.busy(settle))"
                ) {
                    if outdated.developerHome == nil {
                        Button("Restart When Idle", action: outdated.restartWhenIdle)
                            .help("Restarts ompd once no session is starting, resuming or working.")
                        restartNow(settle)
                    }
                }
                .help(Self.tooltip(refusal, settle))
            }
        case .waiting(let settle):
            if case .versionMismatch(let refusal) = app.connection.status {
                NoticeBar(
                    systemImage: "arrow.up.circle", tint: .orange, title: "ompd restarts when idle",
                    message: "This version of Lantern needs a newer ompd. \(Self.busy(settle))", inProgress: true
                ) {
                    restartNow(settle)
                }
                .help(Self.tooltip(refusal, settle))
            }
        }
    }

    private var title: String {
        if outdated.failure != nil { return "Could not restart ompd" }
        return outdated.restartedSinceConnected ? "ompd is still out of date" : "ompd is out of date"
    }

    /// Why the notice is up, and for the developer's ompd what to do.
    private var reason: String {
        if let home = outdated.developerHome {
            return "This version of Lantern needs a newer ompd: restart the one for OMPD_HOME=\(home) with this build's."
        }
        if let failure = outdated.failure { return failure }
        return outdated.restartedSinceConnected ? "The restarted ompd refuses this version of Lantern too." : "This version of Lantern needs a newer ompd."
    }

    private func restartNow(_ settle: ManifestSettle) -> some View {
        Button("Restart Now…") {
            Task {
                if await confirmRestart(settle) { outdated.restartNow() }
            }
        }
        .help("Stops and resumes the sessions now; asks first.")
    }

    /// Asks first, in a sheet on the project's window (the app may be in the background): busy sessions are interrupted.
    private func confirmRestart(_ settle: ManifestSettle) async -> Bool {
        let confirmation = NSAlert()
        confirmation.messageText = "Restart ompd now?"
        confirmation.informativeText = """
            \(Self.busy(settle)) Every running omp session is stopped and resumed by the new ompd. Agents the restart \
            interrupts continue, ask you first or stay stopped, as set in Settings › General › Interrupted Agents.
            """
        confirmation.addButton(withTitle: "Restart Now")
        confirmation.buttons[0].hasDestructiveAction = true
        confirmation.addButton(withTitle: "Cancel")
        let response = if let window = app.window(of: project) ?? NSApp.keyWindow ?? NSApp.mainWindow {
            await confirmation.beginSheetModal(for: window)
        } else {
            confirmation.runModal()
        }
        return response == .alertFirstButtonReturn
    }

    /// What a restart interrupts, as the manifest says.
    private static func busy(_ settle: ManifestSettle) -> String {
        switch settle {
        case .settled: "No session is busy."
        case .unsettled(let sessions): sessions.count == 1 ? "1 session is busy." : "\(sessions.count) sessions are busy."
        case .unreadable: "Lantern cannot tell which sessions are busy."
        }
    }

    private static func tooltip(_ refusal: String, _ settle: ManifestSettle) -> String {
        guard case .unreadable(let why) = settle else { return "ompd: \(refusal)" }
        return "ompd: \(refusal)\nsessions.json: \(why)"
    }
}
