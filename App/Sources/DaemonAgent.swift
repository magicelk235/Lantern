import Foundation
import IDEModel
import Observation
import ServiceManagement

/// Registers ompd, bundled at `Contents/MacOS/ompd` and described by
/// `Contents/Library/LaunchAgents/com.omp-ide.ompd.plist`, as the user's LaunchAgent: launchd keeps it
/// running across app quits, crashes and logins.
///
/// launchd binds the registration to the bundle's Team ID and signing identifier, so rebuilds keep it. A registration
/// made by a bundle signed differently (an ad-hoc build, which Background Task Management cannot spawn at all) still
/// reads as `.enabled` while launchd never starts the daemon; `repair()` redoes it.
@MainActor @Observable
final class DaemonAgent {
    enum State: Equatable {
        case unknown
        /// `OMPD_HOME` is set: a developer runs `ompd run` by hand, so nothing is registered.
        case external(home: String)
        case enabled
        /// Registered, but macOS waits for the user to allow it in System Settings › General › Login Items.
        case requiresApproval
        case notRegistered
        /// The bundle has no such launch agent plist.
        case notFound
        case failed(String)
    }

    private(set) var state: State = .unknown
    /// A `repair()` is under way.
    private(set) var isRepairing = false
    private let service = SMAppService.agent(plistName: "com.omp-ide.ompd.plist")

    func registerIfNeeded() {
        if let home = ProcessInfo.processInfo.environment[AppSupportPaths.homeEnvironmentKey], !home.isEmpty {
            state = .external(home: home)
            return
        }
        switch service.status {
        case .notRegistered, .notFound: register()
        case .enabled, .requiresApproval: refresh()
        @unknown default: refresh()
        }
    }

    /// Registers again until `healthy()` (the app connected to ompd): launchd drops the job it could not spawn and
    /// takes this bundle's plist and signature.
    ///
    /// `SMAppService.unregister()` alone leaves the unspawnable job loaded ("spawn scheduled", bound to the old
    /// Background Task Management record), and `register()` then reuses that record, LWCR failure included; the job
    /// is booted out of the gui domain in between. Even so, the first pass can bind launchd to a record BTM only
    /// replaces with a fresh one (Team ID and all) a few seconds later, so the pass repeats, `repairAttempts` times.
    func repair(untilHealthy healthy: @MainActor () -> Bool) async {
        guard !isRepairing, state == .enabled else { return }
        isRepairing = true
        defer { isRepairing = false }
        for _ in 0..<Self.repairAttempts {
            do {
                try await service.unregister()
            } catch {
                state = .failed(error.localizedDescription)
                return
            }
            await Self.bootOut()
            register()
            guard state == .enabled else { return }
            try? await Task.sleep(for: Self.repairGrace)
            if healthy() { return }
        }
    }

    private static let repairAttempts = 3
    /// How long a freshly registered ompd gets to come up before the next pass.
    private static let repairGrace: Duration = .seconds(6)

    private static let label = "com.omp-ide.ompd"

    /// `launchctl bootout gui/<uid>/com.omp-ide.ompd`, then waits (3 s at most) until launchd no longer lists the job.
    /// launchctl answers "Bad request" for a job in that state and removes it anyway.
    private static func bootOut() async {
        let target = "gui/\(getuid())/\(label)"
        await Task.detached { _ = launchctl("bootout", target) }.value
        for _ in 0..<15 {
            let loaded = await Task.detached { launchctl("print", target) == 0 }.value
            guard loaded else { return }
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    /// Restarts the registered ompd: `launchctl kickstart -k gui/<uid>/com.omp-ide.ompd`. launchd SIGTERMs the one
    /// running, which stops every omp the graceful way, and once it exited (after `ExitTimeOut`, 20 s, at
    /// the latest) spawns the job again: the ompd bundled with the app. Returns why it failed; nil once launchd spawned
    /// the new ompd. Never with `OMPD_HOME` set (`external`): that ompd is the developer's, and the registered one is
    /// not touched.
    func kickstart() async -> String? {
        if case .external(let home) = state { return "ompd runs for OMPD_HOME=\(home); the registered ompd is left alone." }
        let target = "gui/\(getuid())/\(Self.label)"
        let status = await Task.detached { Self.launchctl("kickstart", "-k", target) }.value
        return status == 0 ? nil : "launchctl kickstart exited with status \(status)."
    }

    /// Exit status of `/bin/launchctl <arguments>`; -1 when it could not run.
    private nonisolated static func launchctl(_ arguments: String...) -> Int32 {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }

    private func register() {
        do {
            try service.register()
        } catch {
            refresh()
            // Registration throws when approval is pending; that state speaks for itself.
            if state != .requiresApproval { state = .failed(error.localizedDescription) }
            return
        }
        refresh()
    }

    func refresh() {
        if case .external = state { return }
        switch service.status {
        case .enabled: state = .enabled
        case .requiresApproval: state = .requiresApproval
        case .notRegistered: state = .notRegistered
        case .notFound: state = .notFound
        @unknown default: state = .unknown
        }
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
