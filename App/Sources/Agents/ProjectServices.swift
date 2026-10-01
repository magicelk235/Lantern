import Foundation
import IDEModel

/// The named services of a project, as ompd merges them from omp's broker and its own records, for the Agents pane.
/// One load at a time: a load asked for while one runs follows it. An action reloads the list when it is done.
@MainActor @Observable
final class ProjectServices {
    /// By name.
    private(set) var services: [ServiceInfo] = []
    /// Why the last load failed; nil once one worked.
    var failure: String?
    /// Services an action is under way for.
    private(set) var busy: Set<String> = []
    @ObservationIgnored private var loading: Task<Void, Never>?
    /// A load was asked for while one ran.
    @ObservationIgnored private var stale = false

    /// Loads the list after `delay` (a burst of changes settles meanwhile), or once more after the load under way.
    func load(_ project: String, from connection: DaemonConnection, after delay: Duration = .zero) {
        guard loading == nil else {
            stale = true
            return
        }
        loading = Task {
            if delay > .zero { try? await Task.sleep(for: delay) }
            repeat {
                stale = false
                await fetch(project, from: connection)
            } while stale
            loading = nil
        }
    }

    private func fetch(_ project: String, from connection: DaemonConnection) async {
        guard connection.isConnected else { return }
        do {
            let listed = try await connection.services(in: URL(filePath: project, directoryHint: .isDirectory))
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            if listed != services { services = listed }
            failure = nil
        } catch let error as DaemonError where error.code == .unknownMethod {
            // An ompd from before named-service supervision: it lists none.
            if !services.isEmpty { services = [] }
            failure = nil
        } catch {
            // A connection that dropped meanwhile says nothing about the services.
            if connection.isConnected { failure = error.userMessage }
        }
    }

    /// Stops, kills, restarts or re-modes a service; a refusal is the window's alert.
    func control(
        _ action: ServiceControlRequest.Action, _ service: ServiceInfo, mode: String? = nil, in project: String, app: AppState
    ) {
        busy.insert(service.name)
        Task {
            do {
                let updated = try await app.connection.control(
                    service: service.name, in: URL(filePath: project, directoryHint: .isDirectory), action, mode: mode)
                if let index = services.firstIndex(where: { $0.name == updated.name }) { services[index] = updated }
            } catch {
                app.alert = AppState.AlertMessage(title: Self.failureTitle(action, service.name), message: error.userMessage)
            }
            busy.remove(service.name)
            load(project, from: app.connection)
        }
    }

    private static func failureTitle(_ action: ServiceControlRequest.Action, _ name: String) -> String {
        switch action {
        case .stop: "Could not stop “\(name)”"
        case .kill: "Could not kill “\(name)”"
        case .restart: "Could not restart “\(name)”"
        case .setMode: "Could not change the mode of “\(name)”"
        }
    }
}

extension AppState {
    /// Show Logs: a terminal tab of the project following the service's output (`omp ps logs <name> --follow --dir
    /// <project>`), run by the omp ompd starts the project's sessions with, else by the login shell's `omp`.
    func showLogs(of service: ServiceInfo, in project: String) {
        let arguments = ["ps", "logs", service.name, "--follow", "--dir", project]
        let sessions = connection.sessions.filter { $0.workspace == project }
        let recorder = sessions.filter { $0.sessionKey == service.sessionKey }
        let omp = (recorder + sessions).map(\.launch.ompPath).first { FileManager.default.isExecutableFile(atPath: $0) }
        let command =
            if let omp {
                [omp] + arguments
            } else {
                [Self.loginShell, "-l", "-c", (["omp"] + arguments).map(Self.shellQuoted).joined(separator: " ")]
            }
        newTerminal(in: project, command: command)
    }

    /// The user's login shell (`getpwuid`), else `$SHELL`, else zsh: the shell ompd opens terminals with.
    private static var loginShell: String {
        if let shell = getpwuid(getuid())?.pointee.pw_shell {
            let path = String(cString: shell)
            if !path.isEmpty { return path }
        }
        return ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }

    /// `word` as one word for a POSIX shell.
    private static func shellQuoted(_ word: String) -> String {
        "'" + word.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}
