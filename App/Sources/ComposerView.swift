import IDEModel
import SwiftUI

/// Multi-line prompt editor. ⌘↩ sends; while the agent works it offers Steer (⌘↩) and Follow-up (⌥⌘↩) instead,
/// plus Abort (⌘.).
struct ComposerView: View {
    @Bindable var model: SessionViewModel
    @FocusState private var focused: Bool

    private var trimmedDraft: String { model.draft.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canCommand: Bool { model.isAttached && !model.isClosed }
    private var canSend: Bool { canCommand && !trimmedDraft.isEmpty && !model.isSending }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = model.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            HStack(alignment: .bottom, spacing: 10) {
                editor
                actions
            }
        }
        .padding(12)
        .onAppear { focused = true }
    }

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            // Sizes the editor to its text, between one line and `maxHeight`.
            Text(model.draft.isEmpty ? " " : model.draft + "\n")
                .padding(.horizontal, 5)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .hidden()
            TextEditor(text: $model.draft)
                .scrollContentBackground(.hidden)
                .focused($focused)
                .padding(.vertical, 8)
                .accessibilityLabel("Prompt")
            if model.draft.isEmpty {
                Text(placeholder)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 8)
                    .allowsHitTesting(false)
            }
        }
        .font(.body)
        .frame(minHeight: 38, maxHeight: 180)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 6)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(focused ? Color.accentColor.opacity(0.6) : Color.secondary.opacity(0.3)))
    }

    private var placeholder: String {
        if model.isClosed { return "This session is closed." }
        return model.isBusy ? "Steer the agent, or queue a follow-up…" : "Ask omp… (⌘↩ to send)"
    }

    @ViewBuilder private var actions: some View {
        if model.isBusy {
            VStack(alignment: .trailing, spacing: 6) {
                HStack(spacing: 6) {
                    Button("Steer") { send(.steer) }
                        .keyboardShortcut(.return, modifiers: .command)
                        .help("Deliver now, between tool calls (⌘↩)")
                        .disabled(!canSend)
                    Button("Follow-up") { send(.followUp) }
                        .keyboardShortcut(.return, modifiers: [.command, .option])
                        .help("Deliver after the current turn (⌥⌘↩)")
                        .disabled(!canSend)
                }
                Button(role: .destructive) {
                    Task { await model.abort() }
                } label: {
                    Label("Abort", systemImage: "stop.fill")
                }
                .keyboardShortcut(".", modifiers: .command)
                .help("Stop the run (⌘.)")
                .disabled(!canCommand)
            }
        } else {
            Button {
                send(nil)
            } label: {
                Label("Send", systemImage: "arrow.up.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: .command)
            .help("Send (⌘↩)")
            .disabled(!canSend)
        }
    }

    private func send(_ behavior: StreamingBehavior?) {
        let message = trimmedDraft
        guard !message.isEmpty else { return }
        model.draft = ""
        Task {
            // Put the text back if the daemon did not take it and nothing new was typed meanwhile.
            if await model.send(message, streamingBehavior: behavior) == false, model.draft.isEmpty {
                model.draft = message
            }
        }
    }
}
