import IDEModel
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            TerminalSettingsPane()
                .tabItem { Label("Terminal", systemImage: "terminal") }
        }
        .frame(width: 460, height: 250)
    }
}

private struct GeneralSettings: View {
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
