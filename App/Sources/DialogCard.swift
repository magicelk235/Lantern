import IDEModel
import SwiftUI

/// An `extension_ui_request` omp waits on — tool approvals, `ask` questions, extension dialogs — answered inline
/// through `ui.respond`.
struct DialogCard: View {
    let dialog: Dialog
    let model: SessionViewModel
    @State private var text = ""

    private var isSending: Bool { model.answering.contains(dialog.requestId) }
    private var tint: Color { dialog.approval != nil ? .orange : .accentColor }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let message = dialog.message, !message.isEmpty {
                Text(message).textSelection(.enabled)
            }
            if dialog.isPending {
                controls
                    .disabled(isSending || model.isClosed || !model.isAttached)
                if let expiresAt = dialog.expiresAt, expiresAt > .now {
                    HStack(spacing: 4) {
                        Text("omp picks the default in")
                        Text(timerInterval: Date.now ... expiresAt, countsDown: true)
                            .monospacedDigit()
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            } else {
                resolution
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(dialog.isPending ? 0.10 : 0.04), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(tint.opacity(dialog.isPending ? 0.7 : 0.2), lineWidth: dialog.isPending ? 1.5 : 1))
        .onAppear { if text.isEmpty { text = dialog.prefill ?? "" } }
    }

    @ViewBuilder private var header: some View {
        if let approval = dialog.approval {
            Label("Allow \(approval.toolName)?", systemImage: "hand.raised.fill")
                .font(.headline)
                .foregroundStyle(dialog.isPending ? Color.orange : Color.secondary)
            if !approval.details.isEmpty {
                Text(approval.details.joined(separator: "\n"))
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            }
        } else {
            Label(dialog.title.isEmpty ? "omp is asking" : dialog.title, systemImage: "questionmark.bubble.fill")
                .font(.headline)
                .foregroundStyle(dialog.isPending ? Color.accentColor : Color.secondary)
        }
    }

    @ViewBuilder private var controls: some View {
        switch dialog.kind {
        case .select where dialog.approval != nil:
            HStack {
                Spacer()
                Button("Deny") { answer(.value(Dialog.Approval.deny)) }
                Button("Approve") { answer(.value(Dialog.Approval.approve)) }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
            }
        case .select:
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(dialog.options.enumerated()), id: \.offset) { _, option in
                    Button {
                        answer(.value(option.label))
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(option.label)
                            if let description = option.description, !description.isEmpty {
                                Text(description).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                }
                dismissButton
            }
        case .confirm:
            HStack {
                Spacer()
                Button("No") { answer(.confirmed(false)) }
                Button("Yes") { answer(.confirmed(true)) }
                    .buttonStyle(.borderedProminent)
            }
        case .input:
            HStack {
                TextField(dialog.placeholder ?? "Answer", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { answer(.value(text)) }
                Button("Submit") { answer(.value(text)) }
                    .buttonStyle(.borderedProminent)
                dismissButton
            }
        case .editor:
            VStack(alignment: .trailing, spacing: 6) {
                TextEditor(text: $text)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 80, maxHeight: 220)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .background(.background, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                HStack {
                    dismissButton
                    Button("Submit") { answer(.value(text)) }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return, modifiers: .command)
                }
            }
        }
    }

    private var dismissButton: some View {
        Button("Dismiss") { answer(.cancelled) }
            .help("Answer without choosing. Dismissing an ask stops the whole run.")
    }

    @ViewBuilder private var resolution: some View {
        switch dialog.state {
        case .pending:
            EmptyView()
        case .answered(let answer):
            Label(answeredText(answer), systemImage: "checkmark.circle")
                .font(.callout).foregroundStyle(.secondary)
        case .withdrawn:
            Label("Withdrawn by omp.", systemImage: "arrow.uturn.backward.circle")
                .font(.callout).foregroundStyle(.secondary)
        case .expired:
            Label("Timed out; omp went with the default.", systemImage: "clock.badge.exclamationmark")
                .font(.callout).foregroundStyle(.secondary)
        case .abandoned:
            Label("omp exited before this was answered.", systemImage: "bolt.horizontal.circle")
                .font(.callout).foregroundStyle(.orange)
        }
    }

    private func answeredText(_ sent: DialogResponse?) -> String {
        switch sent {
        case .value(let value) where dialog.approval != nil:
            value == Dialog.Approval.approve ? "Approved." : "Denied."
        case .value(let value): "Answered: \(value)"
        case .confirmed(let confirmed): confirmed ? "Answered: Yes" : "Answered: No"
        case .cancelled: "Dismissed."
        case nil: "Answered."
        }
    }

    private func answer(_ response: DialogResponse) {
        Task { await model.respond(to: dialog.requestId, with: response) }
    }
}
