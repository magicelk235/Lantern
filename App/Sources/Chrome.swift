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
    static let emberColor = dynamic(light: 0xAD581F, dark: 0xF0AC45)
    static let ember = Color(nsColor: emberColor)

    /// The status colors: green idle or live, yellow paused, orange what wants a look or is out of reach (red, what
    /// needs the user, is the system's). The system's colors in dark mode; darker in light mode, where the system's read
    /// 1.4–2.2:1 on the canvas and the surface, so that a mark keeps 3:1 there.
    static let green = Color(nsColor: dynamic(light: 0x069F3C, dark: .systemGreen))
    static let yellow = Color(nsColor: dynamic(light: 0xA88603, dark: .systemYellow))
    static let orange = Color(nsColor: dynamic(light: 0xD36E00, dark: .systemOrange))

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
            srgb(appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light)
        }
    }

    /// An sRGB color (`0xRRGGBB`) for light mode, and a system color for dark mode.
    private static func dynamic(light: Int, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : srgb(light)
        }
    }

    private static func srgb(_ hex: Int) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1)
    }
}

/// One line about a tab or the app, and what the user can do about it: why a session's TUI is not on screen, that a
/// terminal's program ended, that a file changed on disk, that ompd is out of reach. Title and message run in one
/// line; a notice in one sentence has no title, its sentence in the primary color. The actions sit at the trailing edge.
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
        guard !title.isEmpty else { return Text(message) }
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

/// A 7-point status dot. The states a mark shows tell apart by shape as well as color, as the ember of `WorkingDot`
/// and the system's orange and yellow are close in dark mode: a dot is green idle or live, red needs attention, grey
/// parked; a ring (hollow) has no live state, grey once it ended, orange while ompd is out of reach. Paused is
/// `PausedMark`, what wants a look `WarningMark`.
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

/// Paused, as a pause sign the size of a status dot: two yellow bars. White on a selected row, whose highlight is the
/// accent.
struct PausedMark: View {
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        HStack(spacing: 2) {
            RoundedRectangle(cornerRadius: 0.75).frame(width: 2.5)
            RoundedRectangle(cornerRadius: 0.75).frame(width: 2.5)
        }
        .frame(width: 7, height: 8)
        .foregroundStyle(prominence == .increased ? Color.white : Chrome.yellow)
    }
}

/// What wants a look (work omp's death interrupted, a language server that stopped, a service nothing supervises): the
/// system's warning triangle in orange, a little larger than a dot so that its shape reads. White on a selected row.
struct WarningMark: View {
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(prominence == .increased ? Color.white : Chrome.orange)
            .frame(width: 9, height: 9)
            // The words beside it or the label of what it marks say it.
            .accessibilityHidden(true)
    }
}

/// What works, as a dot: the 7-point dot in ember, lit by a soft glow that breathes slowly (steady with Reduce Motion).
/// White on a selected row, whose highlight is the accent.
struct WorkingDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        let onSelection = prominence == .increased
        Circle()
            .fill(onSelection ? Color.white : Chrome.ember)
            .frame(width: 7, height: 7)
            // Wider than the dot without taking room from what sits beside it.
            .background {
                EmberGlow(color: onSelection ? .white : Chrome.emberColor, breathes: !reduceMotion)
                    .frame(width: 15, height: 15)
            }
    }
}

/// The glow behind `WorkingDot`, animated by Core Animation on its own clock: a session working for an hour costs no
/// redraws. Every glow breathes in step with the others.
private struct EmberGlow: NSViewRepresentable {
    let color: NSColor
    let breathes: Bool

    func makeNSView(context: Context) -> GlowView { GlowView() }

    func updateNSView(_ view: GlowView, context: Context) {
        view.color = color
        view.breathes = breathes
    }

    final class GlowView: NSView {
        private let glow = CAGradientLayer()
        /// One breath: brighter, then fainter again.
        private static let period: CFTimeInterval = 2.4

        var breathes = true {
            didSet { if breathes != oldValue { animate() } }
        }
        var color = Chrome.emberColor {
            didSet { if color != oldValue { needsDisplay = true } }
        }

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            glow.type = .radial
            glow.startPoint = CGPoint(x: 0.5, y: 0.5)
            glow.endPoint = CGPoint(x: 1, y: 1)
            layer?.addSublayer(glow)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override var wantsUpdateLayer: Bool { true }

        override func updateLayer() {
            // The color as the view's own appearance has it.
            effectiveAppearance.performAsCurrentDrawingAppearance {
                glow.colors = [color.withAlphaComponent(0.55).cgColor, color.withAlphaComponent(0).cgColor]
            }
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            needsDisplay = true
        }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            glow.frame = bounds
            CATransaction.commit()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            animate()
        }

        /// Clicks go to what the dot is part of.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        private func animate() {
            glow.removeAnimation(forKey: "breathe")
            guard breathes, window != nil else {
                glow.opacity = 0.75
                return
            }
            glow.opacity = 1
            let breath = CABasicAnimation(keyPath: "opacity")
            breath.fromValue = 0.3
            breath.toValue = 1
            breath.duration = Self.period / 2
            breath.autoreverses = true
            breath.repeatCount = .infinity
            breath.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            // In step with every other glow: each starts at the same point of a shared clock.
            let now = CACurrentMediaTime()
            breath.beginTime = glow.convertTime(now - now.truncatingRemainder(dividingBy: Self.period), from: nil)
            glow.add(breath, forKey: "breathe")
        }
    }
}

/// A count in a small capsule, white on red for what waits on the user, on the accent for a plain count; the other way
/// round on a selected row, whose highlight is the accent.
struct CountBadge: View {
    let count: Int
    var tint: Color = .red
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        let onSelection = prominence == .increased
        Text(count > 99 ? "99+" : String(count))
            .font(.system(size: 9, weight: .semibold))
            .monospacedDigit()
            .padding(.horizontal, 4)
            .frame(minWidth: 15, minHeight: 15)
            .background(onSelection ? Color.white : tint, in: Capsule())
            .foregroundStyle(onSelection ? tint : Color.white)
    }
}
