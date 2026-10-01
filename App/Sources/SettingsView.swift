import IDEModel
import SwiftUI

/// A pane of Settings. The one showing is kept in the defaults, so `select()` from elsewhere (Free Up Space…) switches
/// an open Settings window too.
enum SettingsTab: String {
    case general, terminal, storage

    static let defaultsKey = "settingsTab"

    /// The pane Settings shows next (and now, if open).
    func select() {
        UserDefaults.standard.set(rawValue, forKey: Self.defaultsKey)
    }
}

struct SettingsView: View {
    let app: AppState
    @AppStorage(SettingsTab.defaultsKey) private var tab = SettingsTab.general

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings(connection: app.connection)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            TerminalSettingsPane()
                .tabItem { Label("Terminal", systemImage: "terminal") }
                .tag(SettingsTab.terminal)
            StorageSettingsPane(app: app)
                .tabItem { Label("Storage", systemImage: "internaldrive") }
                .tag(SettingsTab.storage)
        }
        .frame(width: 460, height: 360)
    }
}

private struct GeneralSettings: View {
    let connection: DaemonConnection
    @AppStorage(AppSettings.defaultApprovalModeKey) private var approvalMode = ""

    var body: some View {
        Form {
            Section {
                Picker("Approval mode for new sessions", selection: $approvalMode) {
                    Text("Use omp configuration").tag("")
                    Divider()
                    ForEach(ApprovalMode.allCases) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }
            } footer: {
                Text(explanation)
            }
            RestorePolicySection(connection: connection)
        }
        .formStyle(.grouped)
    }

    private var explanation: String {
        let applies = "A running session keeps the mode it started with."
        guard let mode = ApprovalMode(rawValue: approvalMode) else {
            return "omp decides, from tools.approvalMode in your omp config (default: never ask). \(applies)"
        }
        return "\(mode.explanation) \(applies)"
    }
}

/// What ompd does with agents that were mid-task when omp stopped unexpectedly. ompd keeps it, not the
/// defaults: it loads when the pane shows and saves on every change.
private struct RestorePolicySection: View {
    let connection: DaemonConnection
    /// ompd's policy; nil until loaded, and while ompd is out of reach.
    @State private var policy: RestorePolicy?
    @State private var failure: String?

    var body: some View {
        Section {
            Picker("Main agent", selection: binding(\.main)) { options }
            Picker("Subagents", selection: binding(\.subagents)) { options }
        } header: {
            Text("Interrupted Agents")
        } footer: {
            Text(footer)
        }
        .disabled(policy == nil)
        .task(id: connection.isConnected) { await load() }
    }

    @ViewBuilder private var options: some View {
        ForEach(ContinuePolicy.allCases, id: \.self) { choice in
            Text(choice.title).tag(choice)
        }
    }

    private var footer: String {
        if !connection.isConnected { return "Available while ompd is running." }
        if let failure { return failure }
        return "When omp stops unexpectedly, ompd starts it again. Agents that were mid-task can then carry on; Ask shows a bar in the session's tab."
    }

    private func binding(_ keyPath: WritableKeyPath<RestorePolicy, ContinuePolicy>) -> Binding<ContinuePolicy> {
        Binding {
            (policy ?? RestorePolicy())[keyPath: keyPath]
        } set: { choice in
            guard var changed = policy, changed[keyPath: keyPath] != choice else { return }
            changed[keyPath: keyPath] = choice
            policy = changed
            Task { await save(changed) }
        }
    }

    private func load() async {
        guard connection.isConnected else {
            policy = nil
            failure = nil
            return
        }
        do {
            policy = try await connection.restorePolicy()
            failure = nil
        } catch {
            policy = nil
            failure = "Could not load this setting: \(error.userMessage)"
        }
    }

    private func save(_ changed: RestorePolicy) async {
        do {
            policy = try await connection.setRestorePolicy(changed)
            failure = nil
        } catch {
            let message = "Could not save this setting: \(error.userMessage)"
            await load()
            failure = message
        }
    }
}

private extension ContinuePolicy {
    var title: String {
        switch self {
        case .auto: "Continue automatically"
        case .ask: "Ask"
        case .never: "Don't continue"
        }
    }
}

private struct TerminalSettingsPane: View {
    @AppStorage(TerminalSettings.fontSizeKey) private var fontSize = TerminalSettings.defaultFontSize
    @AppStorage(TerminalSettings.sessionOptionAsMetaKey) private var sessionOptionAsMeta = true
    @AppStorage(TerminalSettings.terminalOptionAsMetaKey) private var terminalOptionAsMeta = true

    var body: some View {
        Form {
            Section {
                LabeledContent("Font size") {
                    Stepper(value: $fontSize, in: TerminalSettings.fontSizes, step: 1) {
                        Text("\(Int(fontSize)) pt").monospacedDigit()
                    }
                }
            }
            Section {
                Toggle("Option sends Meta in omp sessions", isOn: $sessionOptionAsMeta)
                Toggle("Option sends Meta in terminals", isOn: $terminalOptionAsMeta)
            } footer: {
                Text("On, Option+key reaches the program as Alt+key (omp's Alt+P, Alt+M, …). Off, Option types the characters of your keyboard layout.")
            }
        }
        .formStyle(.grouped)
    }
}
