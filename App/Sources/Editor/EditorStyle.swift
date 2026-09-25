import AppKit
import CodeEditSourceEditor

/// How editors look and indent: the system monospaced font and a theme after Xcode's default colors.
///
/// CodeEditSourceEditor reads components of the theme's colors (brightness, `CGColor`), which dynamic system colors do
/// not have, so every theme is made of concrete sRGB colors for one appearance; editors get a new one when the system
/// appearance changes (`Editors`).
@MainActor
enum EditorStyle {
    static func configuration(indent: IndentOption, appearance: NSAppearance) -> SourceEditorConfiguration {
        SourceEditorConfiguration(
            appearance: .init(
                theme: theme(for: appearance), font: .monospacedSystemFont(ofSize: 12, weight: .regular),
                lineHeightMultiple: 1.25, wrapLines: false, tabWidth: 4),
            behavior: .init(indentOption: indent),
            // Below the tab strip, not under the toolbar: no automatic safe-area inset.
            layout: .init(editorOverscroll: 0.25, contentInsets: NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)),
            peripherals: .init(showMinimap: false))
    }

    /// Tabs when more of the first lines that are indented start with a tab than with spaces, else four spaces.
    static func indent(of text: String) -> IndentOption {
        var tabs = 0
        var spaces = 0
        for line in text.split(separator: "\n", maxSplits: 2000, omittingEmptySubsequences: true).prefix(2000) {
            switch line.first {
            case "\t": tabs += 1
            case " ": spaces += 1
            default: break
            }
        }
        return tabs > spaces ? .tab : .spaces(count: 4)
    }

    private static func theme(for appearance: NSAppearance) -> EditorTheme {
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let pick = { (light: Int, darkHex: Int) in rgb(dark ? darkHex : light) }
        var system: (text: NSColor, invisibles: NSColor, background: NSColor, selection: NSColor, accent: NSColor)!
        appearance.performAsCurrentDrawingAppearance {
            system = (
                concrete(.textColor), concrete(.tertiaryLabelColor), concrete(.textBackgroundColor),
                concrete(.selectedTextBackgroundColor), concrete(.controlAccentColor))
        }
        return EditorTheme(
            text: .init(color: system.text),
            insertionPoint: system.accent,
            invisibles: .init(color: system.invisibles),
            background: system.background,
            lineHighlight: dark ? NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.06) : NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.04),
            selection: system.selection,
            keywords: .init(color: pick(0x9B2393, 0xFF7AB2), bold: true),
            commands: .init(color: pick(0x326D74, 0x67B7A4)),
            types: .init(color: pick(0x3900A0, 0xDABAFF)),
            attributes: .init(color: pick(0x815F03, 0xCC9768)),
            variables: .init(color: pick(0x0F68A0, 0x4EB0CC)),
            values: .init(color: pick(0x6C36A9, 0xA167E6)),
            numbers: .init(color: pick(0x1C00CF, 0xD9C97C)),
            strings: .init(color: pick(0xC41A16, 0xFF8170)),
            characters: .init(color: pick(0x1C00CF, 0xD9C97C)),
            comments: .init(color: pick(0x5D6C79, 0x7F8C98)))
    }

    /// `color` resolved for the current drawing appearance.
    private static func concrete(_ color: NSColor) -> NSColor {
        color.usingColorSpace(.sRGB) ?? color
    }

    private static func rgb(_ hex: Int) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
