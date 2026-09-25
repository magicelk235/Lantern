import Foundation
import IDEModel
import Observation
import Security
import ServiceManagement

/// Registers ompd, bundled at `Contents/MacOS/ompd` and described by
/// `Contents/Library/LaunchAgents/com.omp-ide.ompd.plist`, as the user's LaunchAgent: launchd keeps it
/// running across app quits, crashes and logins.
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
    private let service = SMAppService.agent(plistName: "com.omp-ide.ompd.plist")
    /// cdhash of the `ompd` the current registration was made for. launchd's Background Task Management record is
    /// bound to the bundle's code signature, so after a rebuild or an update the old registration can no longer spawn
    /// the daemon (xpcproxy exits 78, BTM error -95) while `status` still reports `.enabled`.
    private static let registeredDaemonKey = "registeredDaemonCDHash"

    func registerIfNeeded() {
        if let home = ProcessInfo.processInfo.environment[AppSupportPaths.homeEnvironmentKey], !home.isEmpty {
            state = .external(home: home)
            return
        }
        let current = Self.bundledDaemonCDHash()
        let registeredFor = UserDefaults.standard.string(forKey: Self.registeredDaemonKey)
        switch service.status {
        case .enabled, .requiresApproval:
            guard let current, current != registeredFor else { break }
            // Registered for a different ompd binary: re-register so launchd picks up this bundle's signature.
            Task { await reregister(recording: current) }
            return
        case .notRegistered, .notFound:
            register(recording: current)
            return
        @unknown default:
            break
        }
        refresh()
    }

    private func reregister(recording hash: String) async {
        do {
            try await service.unregister()
        } catch {
            state = .failed(error.localizedDescription)
            return
        }
        register(recording: hash)
    }

    private func register(recording hash: String?) {
        do {
            try service.register()
            if let hash { UserDefaults.standard.set(hash, forKey: Self.registeredDaemonKey) }
        } catch {
            refresh()
            // Registration throws when approval is pending; that state speaks for itself.
            if state != .requiresApproval { state = .failed(error.localizedDescription) }
            return
        }
        refresh()
    }

    /// Unique code identity (cdhash) of `Contents/MacOS/ompd`; nil when the binary is missing or unsigned.
    private static func bundledDaemonCDHash() -> String? {
        let url = Bundle.main.bundleURL.appending(path: "Contents/MacOS/ompd", directoryHint: .notDirectory)
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any], let unique = dict[kSecCodeInfoUnique as String] as? Data
        else { return nil }
        return unique.map { String(format: "%02x", $0) }.joined()
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
