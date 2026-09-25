import IDEModel
import SwiftUI

struct SettingsView: View {
    @AppStorage(AppSettings.defaultApprovalModeKey) private var approvalMode = ""
    @AppStorage(TerminalSettings.fontSizeKey) private var terminalFontSize = TerminalSettings.defaultFontSize

    var body: some View {
        Form {
            Picker("Default approval mode", selection: $approvalMode) {
                Text("Use omp configuration").tag("")
                Divider()
                ForEach(ApprovalMode.allCases) { mode in
                    Text(mode.title).tag(mode.rawValue)
                }
            }
            Text(explanation)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            LabeledContent("Terminal font size") {
                Stepper(value: $terminalFontSize, in: TerminalSettings.fontSizes, step: 1) {
                    Text("\(Int(terminalFontSize)) pt").monospacedDigit()
                }
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private var explanation: String {
        let applies = "Applies to sessions you start from now on; a running session keeps the mode it started with."
        guard let mode = ApprovalMode(rawValue: approvalMode) else {
            return "omp decides, from tools.approvalMode in your omp config (default: never ask). \(applies)"
        }
        return "\(mode.explanation) \(applies)"
    }
}
