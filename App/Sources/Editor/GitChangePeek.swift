import SwiftUI

/// What a click on a gutter mark shows: the mark again with what it means ("Changed 1 line"), which change of how many
/// with Previous and Next, the one action that undoes it, and HEAD's lines it replaced (the text's own are right
/// above, in the editor). Esc or a click elsewhere closes it, as any popover.
struct GitChangePeek: View {
    let change: GitGutterMarks.Change
    /// 1-based.
    let position: Int
    let count: Int
    let width: CGFloat
    let revert: () -> Void
    let previous: () -> Void
    let next: () -> Void

    static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private static let lineHeight = ceil(font.ascender - font.descender + font.leading)
    private static let maxLines = 12
    static let bodyPadding: CGFloat = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !change.removed.isEmpty {
                Divider()
                removedLines
            }
        }
        .frame(width: width)
    }

    private var header: some View {
        HStack(spacing: 8) {
            mark
            Text(title)
                .fontWeight(.medium)
            Spacer(minLength: 12)
            if count > 1 {
                Text("\(position) of \(count)")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                HStack(spacing: 0) {
                    step("Previous Change", "chevron.up", previous)
                    step("Next Change", "chevron.down", next)
                }
            }
            Button(actionTitle, action: revert)
                .controlSize(.small)
        }
        .font(.system(size: 13))
        .padding(.horizontal, Self.bodyPadding)
        .padding(.vertical, 8)
    }

    /// The gutter's own mark: a bar in its color, or the deletion's triangle.
    @ViewBuilder private var mark: some View {
        switch change.kind {
        case .modified:
            RoundedRectangle(cornerRadius: 1).fill(Color(nsColor: .systemBlue)).frame(width: 3, height: 13)
        case .added:
            RoundedRectangle(cornerRadius: 1).fill(Color(nsColor: .systemGreen)).frame(width: 3, height: 13)
        case .deleted:
            Triangle().fill(Color(nsColor: .systemRed)).frame(width: 6, height: 8)
        }
    }

    private var removedLines: some View {
        let numberWidth = CGFloat(String(change.oldStart + change.removed.count - 1).count) * Self.digitWidth
        return ScrollView([.vertical, .horizontal]) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(change.removed.enumerated()), id: \.offset) { offset, line in
                    HStack(spacing: 10) {
                        Text(String(change.oldStart + offset))
                            .foregroundStyle(.tertiary)
                            .frame(width: numberWidth, alignment: .trailing)
                        Text(line.isEmpty ? " " : line.replacingOccurrences(of: "\t", with: "    "))
                            .fixedSize()
                    }
                    .frame(height: Self.lineHeight)
                }
            }
            .font(Font(Self.font))
            .textSelection(.enabled)
            .padding(.horizontal, Self.bodyPadding)
            .padding(.vertical, 8)
            .frame(minWidth: width, alignment: .leading)
        }
        .frame(height: CGFloat(min(change.removed.count, Self.maxLines)) * Self.lineHeight + 16)
    }

    private var title: String {
        let lines = change.kind == .deleted ? change.removed.count : change.lines.count
        let noun = lines == 1 ? "line" : "lines"
        switch change.kind {
        case .modified: return "Changed \(lines) \(noun)"
        case .added: return "Added \(lines) \(noun)"
        case .deleted: return "Deleted \(lines) \(noun)"
        }
    }

    private var actionTitle: String {
        switch change.kind {
        case .modified: "Revert"
        case .added: "Remove"
        case .deleted: "Restore"
        }
    }

    private func step(_ title: String, _ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help(title)
        .accessibilityLabel(title)
    }

    static var digitWidth: CGFloat {
        ("0" as NSString).size(withAttributes: [.font: font]).width
    }

    /// The width that fits HEAD's lines (their numbers, the text, the padding), between `minimum` and `maximum`.
    static func width(for change: GitGutterMarks.Change, minimum: CGFloat = 300, maximum: CGFloat) -> CGFloat {
        let longest = change.removed.map { $0.replacingOccurrences(of: "\t", with: "    ").count }.max() ?? 0
        let numbers = String(change.oldStart + max(0, change.removed.count - 1)).count
        let fitting = CGFloat(longest + numbers) * digitWidth + 10 + bodyPadding * 2
        return min(max(fitting, minimum), max(minimum, maximum))
    }
}

/// A triangle pointing right, as the gutter draws a deletion.
private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
