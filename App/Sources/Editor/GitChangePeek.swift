import IDEEditorModel
import SwiftUI

/// What a click on a gutter mark shows, after VS Code's quick diff peek: the file's name, which change of how many,
/// Revert, Previous, Next and Close, over the change as a unified diff with a few lines around it (HEAD's lines red, the
/// text's green).
struct GitChangePeek: View {
    let fileName: String
    /// 1-based.
    let position: Int
    let count: Int
    let rows: [LineDiff.Line]
    let width: CGFloat
    let revert: () -> Void
    let previous: () -> Void
    let next: () -> Void
    let close: () -> Void

    private static let rowHeight: CGFloat = 17
    private static let maxRows = 18

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(fileName)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(count == 1 ? "1 change" : "\(position) of \(count) changes")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer(minLength: 8)
                button("Revert Change", "arrow.uturn.backward", revert)
                button("Previous Change", "chevron.up", previous)
                    .disabled(count < 2)
                button("Next Change", "chevron.down", next)
                    .disabled(count < 2)
                button("Close", "xmark", close)
                    .keyboardShortcut(.cancelAction)
            }
            .font(.system(size: 12))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()
            ScrollView([.vertical, .horizontal]) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, line in
                        DiffLineRow(line: line)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    // At least the peek's width, so every row's wash spans it and not only its text.
                    Color.clear.frame(width: width, height: 0)
                }
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
            }
            .frame(height: CGFloat(min(rows.count, Self.maxRows)) * Self.rowHeight + 4)
        }
        .frame(width: width)
    }

    private func button(_ title: String, _ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(title)
        .accessibilityLabel(title)
    }
}
