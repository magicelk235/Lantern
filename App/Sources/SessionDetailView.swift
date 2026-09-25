import IDEModel
import SwiftUI

struct SessionDetailView: View {
    let model: SessionViewModel
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            TranscriptView(model: model)
            Divider()
            ComposerView(model: model)
        }
        .navigationTitle(model.entry?.displayTitle ?? model.sessionKey)
        .navigationSubtitle(model.entry?.workspace ?? "")
        .toolbar {
            ToolbarItem(placement: .status) {
                SyncIndicator(sync: model.sync, activity: model.transcript.activity)
            }
            ToolbarItem {
                Button("Close Session", systemImage: "xmark.circle", action: onClose)
                    .help("Stop omp for this session (the transcript stays readable)")
                    .disabled(model.isClosed || !model.isAttached)
            }
        }
    }
}

struct SyncIndicator: View {
    let sync: SessionViewModel.SyncState
    let activity: TranscriptReducer.Activity

    var body: some View {
        switch sync {
        case .detached:
            Label("Offline", systemImage: "wifi.slash").foregroundStyle(.secondary)
        case .subscribing:
            Label("Replaying…", systemImage: "arrow.clockwise").foregroundStyle(.secondary)
        case .resyncing:
            Label("Rebuilding…", systemImage: "arrow.triangle.2.circlepath").foregroundStyle(.secondary)
        case .failed(let message):
            Label("Unavailable", systemImage: "exclamationmark.triangle").foregroundStyle(.orange).help(message)
        case .live:
            switch activity {
            case .streaming: Label("Streaming", systemImage: "waveform").foregroundStyle(.tint)
            case .working: Label("Working", systemImage: "hourglass").foregroundStyle(.secondary)
            case .idle: Label("Idle", systemImage: "checkmark.circle").foregroundStyle(.secondary)
            }
        }
    }
}

/// The session's transcript. While the end marker is the row at the bottom edge, new output keeps the view pinned to
/// the bottom; scrolling up anchors an older row instead (output then grows out of view), scrolling back down re-pins.
struct TranscriptView: View {
    let model: SessionViewModel
    @State private var bottomRow: String? = TranscriptView.end
    private static let end = "transcript-end"

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(model.items) { item in
                    TranscriptRow(item: item, model: model)
                        .opacity(item.isLost ? 0.45 : 1)
                        .help(item.isLost ? "omp never saved this output; it is not part of the model's context" : "")
                }
                Color.clear
                    .frame(height: 1)
                    .id(Self.end)
            }
            .scrollTargetLayout()
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollPosition(id: $bottomRow, anchor: .bottom)
        .overlay {
            if model.items.isEmpty { emptyState }
        }
    }

    @ViewBuilder private var emptyState: some View {
        switch model.sync {
        case .subscribing, .resyncing:
            ProgressView("Loading transcript…")
        case .failed(let message):
            ContentUnavailableView("Session Unavailable", systemImage: "exclamationmark.triangle", description: Text(message))
        case .detached, .live:
            ContentUnavailableView("Nothing Yet", systemImage: "text.bubble", description: Text("Send a prompt to start."))
        }
    }
}

struct TranscriptRow: View {
    let item: TranscriptItem
    let model: SessionViewModel

    var body: some View {
        switch item.content {
        case .user(let message):
            UserMessageView(message: message)
        case .assistant(let message):
            if !message.isEmpty { AssistantMessageView(message: message) }
        case .tool(let tool):
            ToolCallCard(tool: tool)
        case .dialog(let dialog):
            DialogCard(dialog: dialog, model: model)
        case .notice(let notice):
            NoticeRow(notice: notice)
        }
    }
}

struct UserMessageView: View {
    let message: UserMessage

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "person.fill")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 4) {
                Text(message.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if message.imageCount > 0 {
                    Label("\(message.imageCount) image\(message.imageCount == 1 ? "" : "s")", systemImage: "photo")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .background(Color.accentColor.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct AssistantMessageView: View {
    let message: AssistantMessage

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "sparkle")
                .foregroundStyle(.purple)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(message.blocks.enumerated()), id: \.offset) { position, block in
                    switch block.kind {
                    case .thinking:
                        if !block.text.isEmpty {
                            ThinkingView(text: block.text, isLive: message.isStreaming && position == message.blocks.count - 1)
                        }
                    case .text:
                        if message.isStreaming {
                            Text(block.text + (position == message.blocks.count - 1 ? " ▍" : ""))
                                .textSelection(.enabled)
                        } else {
                            MarkdownText(text: block.text)
                        }
                    }
                }
                if message.isStreaming && message.blocks.isEmpty {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Thinking…").foregroundStyle(.secondary)
                    }
                }
                if let error = message.errorMessage {
                    Label(error, systemImage: message.stopReason == "aborted" ? "stop.circle" : "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(message.stopReason == "aborted" ? Color.secondary : Color.red)
                }
                if message.wasInterrupted {
                    Label("omp stopped while this message was streaming.", systemImage: "bolt.horizontal.circle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct ThinkingView: View {
    let text: String
    let isLive: Bool
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
        } label: {
            Label(isLive ? "Thinking…" : "Thought for a moment", systemImage: "brain")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

struct NoticeRow: View {
    let notice: Notice
    @State private var expanded = false

    var body: some View {
        switch notice.kind {
        case .stderr:
            DisclosureGroup(isExpanded: $expanded) {
                Text(notice.text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Label("omp stderr", systemImage: "terminal")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .lost:
            Label(notice.text, systemImage: "exclamationmark.icloud")
                .font(.callout)
                .foregroundStyle(.orange)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        default:
            Label(notice.text, systemImage: icon)
                .font(.callout)
                .foregroundStyle(color)
                .textSelection(.enabled)
        }
    }

    private var icon: String {
        switch notice.kind {
        case .retry: "arrow.clockwise"
        case .compaction: "rectangle.compress.vertical"
        case .process: notice.level == .info ? "power" : "bolt.horizontal.circle"
        case .outcome: notice.level == .error ? "xmark.octagon" : "stop.circle"
        case .extensionMessage: "puzzlepiece.extension"
        case .message, .lost, .stderr: notice.level == .info ? "info.circle" : "exclamationmark.triangle"
        }
    }

    private var color: Color {
        switch notice.level {
        case .info: .secondary
        case .warning: .orange
        case .error: .red
        }
    }
}
