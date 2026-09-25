import IDEModel
import SwiftUI

/// One tool call: name, what it acts on, status, and a monospaced tail of its output.
struct ToolCallCard: View {
    let tool: ToolCall
    @State private var expanded = false

    /// Lines of output shown while the call runs (or failed) and the card is collapsed.
    private static let tailLines = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                statusIcon
                    .frame(width: 16)
                Text(tool.name)
                    .fontWeight(.semibold)
                Text(tool.summary)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(tool.summary)
                Spacer(minLength: 8)
                if !tool.output.isEmpty {
                    Button(expanded ? "Less" : "Output") { expanded.toggle() }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
            .font(.system(.callout, design: .monospaced))
            if let intent = tool.intent, !intent.isEmpty {
                Text(intent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 24)
            }
            if let output = visibleOutput {
                ScrollView {
                    Text(output)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: expanded ? 320 : 160)
                .padding(8)
                .background(.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(10)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(borderColor, lineWidth: 1))
    }

    private var visibleOutput: String? {
        guard !tool.output.isEmpty else { return nil }
        let prefix = tool.outputIsTruncated ? "…\n" : ""
        if expanded { return prefix + tool.output }
        guard tool.status == .running || tool.status == .failed else { return nil }
        let lines = tool.output.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > Self.tailLines else { return prefix + tool.output }
        return "…\n" + lines.suffix(Self.tailLines).joined(separator: "\n")
    }

    @ViewBuilder private var statusIcon: some View {
        switch tool.status {
        case .composing:
            Image(systemName: "ellipsis").foregroundStyle(.secondary).help("The model is writing this call")
        case .pending:
            Image(systemName: "clock").foregroundStyle(.secondary).help("Waiting to run")
        case .running:
            ProgressView().controlSize(.small).help("Running")
        case .succeeded:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help("Done")
        case .failed:
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red).help("Failed")
        case .interrupted:
            Image(systemName: "bolt.horizontal.circle").foregroundStyle(.orange).help("omp stopped before this call finished")
        }
    }

    private var borderColor: Color {
        switch tool.status {
        case .failed: .red.opacity(0.4)
        case .interrupted: .orange.opacity(0.4)
        case .running: .accentColor.opacity(0.4)
        case .composing, .pending, .succeeded: .secondary.opacity(0.2)
        }
    }
}
