import SwiftUI

/// The window chrome's surfaces and measures. Two surfaces: the canvas terminals and editors draw
/// on, and the window's own surface for every bar around them; hairlines separate them, never shadows.
enum Chrome {
    static let tabStripHeight: CGFloat = 30
    static let statusBarHeight: CGFloat = 22

    static let canvas = Color(nsColor: .textBackgroundColor)
    /// Reads a step behind the canvas in light and dark mode alike (`windowBackgroundColor` is nearly white in light).
    static let surface = Color(nsColor: .underPageBackgroundColor)
    static let hairline = Color(nsColor: .separatorColor)

    /// Git marks in the Files pane: a file (or a folder holding one) new to the repository, or changed.
    /// The system green and yellow in dark mode; darker in light mode, where those two fail against white.
    static let gitAdded = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .systemGreen : NSColor(red: 0.12, green: 0.5, blue: 0.2, alpha: 1)
    })
    static let gitModified = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .systemYellow : NSColor(red: 0.62, green: 0.45, blue: 0, alpha: 1)
    })
}

/// One line about a tab or the app, and what the user can do about it: why a session's TUI is not on screen, that a
/// terminal's program ended, that a file changed on disk, that ompd is out of reach. Title and message run in one
/// line; the actions sit at the trailing edge.
struct NoticeBar<Actions: View>: View {
    let systemImage: String
    let tint: Color
    let title: String
    var message = ""
    /// Something is under way that ends the notice by itself: a spinner instead of the icon.
    var inProgress = false
    /// Where the hairline goes: `.bottom` over the content, `.top` under it.
    var rule: Alignment = .bottom
    @ViewBuilder let actions: Actions

    var body: some View {
        HStack(spacing: 8) {
            if inProgress {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(tint)
                    .frame(width: 16)
            }
            text.lineLimit(2)
            Spacer(minLength: 12)
            HStack(spacing: 6) { actions }
                .controlSize(.small)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, minHeight: 32)
        .background(tint.opacity(0.1))
        .overlay(alignment: rule) { Divider() }
    }

    private var text: Text {
        let title = Text(title).fontWeight(.medium)
        guard !message.isEmpty else { return title }
        return title + Text("  ") + Text(message).foregroundStyle(.secondary)
    }
}

extension NoticeBar where Actions == EmptyView {
    init(systemImage: String, tint: Color, title: String, message: String = "", inProgress: Bool = false, rule: Alignment = .bottom) {
        self.init(
            systemImage: systemImage, tint: tint, title: title, message: message, inProgress: inProgress, rule: rule,
            actions: { EmptyView() })
    }
}

/// A 7-point status dot; hollow for something that ended.
struct StatusDot: View {
    let color: Color
    var hollow = false

    var body: some View {
        Group {
            if hollow {
                Circle().strokeBorder(color, lineWidth: 1.5)
            } else {
                Circle().fill(color)
            }
        }
        .frame(width: 7, height: 7)
    }
}
