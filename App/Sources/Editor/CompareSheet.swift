import IDEEditorModel
import SwiftUI

/// The file on disk against the unsaved text, as a unified line diff: `−` lines are only on disk, `+` lines only in
/// the editor.
struct CompareSheet: View {
    let document: EditorDocument
    let comparison: EditorDocument.Comparison
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        DiffSheet(
            title: "“\(document.name)” on disk and in the editor", removedLegend: "− only on disk",
            insertedLegend: "+ only in your unsaved version", hunks: comparison.hunks
        ) {
            Button("Keep Mine") {
                document.keepMine()
                dismiss()
            }
            Button("Reload from Disk") {
                document.revert()
                dismiss()
            }
            Spacer()
            Button("Close") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
    }
}

/// A sheet that shows one unified line diff: a title, two legends, the hunks (or "No differences"), and the actions
/// under a hairline, Close last. `CompareSheet` and `ChangeDiffSheet` are made of it. Every row is as wide as the
/// view, or as the widest line shown so far, so the red and green washes span it.
struct DiffSheet<Actions: View>: View {
    let title: String
    let removedLegend: String
    let insertedLegend: String
    let hunks: [LineDiff.Hunk]
    @ViewBuilder let actions: Actions
    @State private var visibleWidth = 0.0
    /// Rows lay out lazily: the widest seen so far.
    @State private var widestLine = 0.0

    private var rowWidth: Double { max(visibleWidth, widestLine) }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                HStack(spacing: 14) {
                    Legend(color: .red, text: removedLegend)
                    Legend(color: .green, text: insertedLegend)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            Divider()
            if hunks.isEmpty {
                ContentUnavailableView("No differences", systemImage: "equal", description: Text("The texts are the same."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(hunks.enumerated()), id: \.offset) { _, hunk in
                            Text(hunk.header)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .frame(minWidth: rowWidth, alignment: .leading)
                                .background(Color.secondary.opacity(0.08))
                            ForEach(Array(hunk.lines.enumerated()), id: \.offset) { _, line in
                                DiffLineRow(line: line, width: rowWidth) { if $0 > widestLine { widestLine = $0 } }
                            }
                        }
                    }
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                }
                .onGeometryChange(for: Double.self) { Double($0.size.width) } action: { visibleWidth = $0 }
            }
            Divider()
            HStack { actions }
                .padding(12)
        }
        .frame(minWidth: 720, idealWidth: 900, minHeight: 420, idealHeight: 620)
    }
}

private struct Legend: View {
    let color: Color
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(color.opacity(0.35)).frame(width: 10, height: 10)
            Text(text)
        }
    }
}

private struct DiffLineRow: View {
    let line: LineDiff.Line
    /// The row's width at least: its wash spans it.
    let width: Double
    /// Hears the width the line's text needs.
    let measured: (Double) -> Void

    var body: some View {
        HStack(spacing: 0) {
            number(line.oldNumber)
            number(line.newNumber)
            Text(marker)
                .frame(width: 16)
            Text(line.text.isEmpty ? " " : line.text)
                .fixedSize(horizontal: true, vertical: false)
        }
        .onGeometryChange(for: Double.self) { Double($0.size.width) } action: { measured($0) }
        .frame(minWidth: width, alignment: .leading)
        .padding(.vertical, 1)
        .background(background)
    }

    private func number(_ value: Int?) -> some View {
        Text(value.map(String.init) ?? "")
            .foregroundStyle(.tertiary)
            .frame(width: 48, alignment: .trailing)
            .padding(.trailing, 6)
    }

    private var marker: String {
        switch line.kind {
        case .context: " "
        case .removed: "−"
        case .inserted: "+"
        }
    }

    private var background: Color {
        switch line.kind {
        case .context: .clear
        case .removed: .red.opacity(0.14)
        case .inserted: .green.opacity(0.14)
        }
    }
}
