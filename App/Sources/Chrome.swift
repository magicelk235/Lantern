import AppKit
import SwiftUI

/// The window chrome's surfaces and measures. Two surfaces: the canvas terminals and editors draw on, and the window's
/// own surface for every bar around them; hairlines separate them, never shadows. Both lean a little toward the icon's
/// ember (OKLCH chroma 0.006–0.01, at the system's own lightness), and neither is pure white or black.
enum Chrome {
    static let tabStripHeight: CGFloat = 30
    static let statusBarHeight: CGFloat = 22

    /// Terminals, editors, empty states and the selected tab.
    static let canvasColor = dynamic(light: 0xFFFCF8, dark: 0x211D1B)
    /// The toolbar, the rail, the panes, the tab strip and the status bar: a step behind the canvas in light and dark
    /// mode alike, as `underPageBackgroundColor` is.
    static let surfaceColor = dynamic(light: 0xFAF5F1, dark: 0x2C2723)
    static let canvas = Color(nsColor: canvasColor)
    static let surface = Color(nsColor: surfaceColor)
    static let hairline = Color(nsColor: .separatorColor)

    /// What works: a session or an agent omp is busy with, and the status bar's "Working". The icon's ember: its lit
    /// amber in dark mode, its deep ember in light mode, where amber is too faint on the surfaces (4.6:1 there).
    static let ember = Color(nsColor: dynamic(light: 0xAD581F, dark: 0xF0AC45))

    /// Git marks in the Files pane: a file (or a folder holding one) new to the repository, or changed.
    /// The system green and yellow in dark mode; darker in light mode, where those two fail against white.
    static let gitAdded = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .systemGreen : NSColor(red: 0.12, green: 0.5, blue: 0.2, alpha: 1)
    })
    static let gitModified = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .systemYellow : NSColor(red: 0.62, green: 0.45, blue: 0, alpha: 1)
    })

    /// One sRGB color (`0xRRGGBB`) for light mode and one for dark mode.
    private static func dynamic(light: Int, dark: Int) -> NSColor {
        NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
    }
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
