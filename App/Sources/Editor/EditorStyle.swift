import AppKit
import CodeEditSourceEditor
import IDEExtensions

/// Point size of editor text (SF Mono), changed by View › Bigger, Smaller and Actual Size; every editor follows it
/// (`Editors`).
enum EditorSettings {
    static let fontSizeKey = "editorFontSize"
    static let defaultFontSize = 12.0
    static let fontSizes = 9.0 ... 24.0

    static var fontSize: Double {
        let size = UserDefaults.lantern.double(forKey: fontSizeKey)
        return size == 0 ? defaultFontSize : min(max(size, fontSizes.lowerBound), fontSizes.upperBound)
    }
}

/// How editors look and indent: the system monospaced font and a theme after Xcode's default colors, on Lantern's canvas,
/// or the VS Code theme picked for the appearance in Settings › Extensions.
///
/// CodeEditSourceEditor reads components of the theme's colors (brightness, `CGColor`), which dynamic colors do not
/// have, so every theme is made of concrete sRGB colors for one appearance; editors get a new one when the system
/// appearance changes or another theme is picked (`Editors`).
@MainActor
enum EditorStyle {
    static func configuration(indent: IndentOption, appearance: NSAppearance) -> SourceEditorConfiguration {
        SourceEditorConfiguration(
            appearance: .init(
                theme: theme(for: appearance), font: .monospacedSystemFont(ofSize: EditorSettings.fontSize, weight: .regular),
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
                concrete(.textColor), concrete(.tertiaryLabelColor), concrete(Chrome.canvasColor),
                concrete(.selectedTextBackgroundColor), concrete(.controlAccentColor))
        }
        if let picked = EditorExtensions.shared.colorTheme(dark: dark) {
            return theme(from: picked, selection: system.selection)
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

    /// An editor theme of `picked`'s colors. What it leaves out is VS Code's default for a theme of its kind (light or
    /// dark), and a syntax category it has no color for takes its text color.
    private static func theme(from picked: ColorTheme, selection systemSelection: NSColor) -> EditorTheme {
        let dark = picked.isDark
        let text = picked.foreground.map(color) ?? rgb(dark ? 0xD4D4D4 : 0x000000)
        let background = (picked.background.map(color) ?? rgb(dark ? 0x1E1E1E : 0xFFFFFF)).withAlphaComponent(1)
        func attribute(_ category: SyntaxCategory) -> EditorTheme.Attribute {
            let style = picked.style(for: category)
            return .init(color: style?.color.map(color) ?? text, bold: style?.bold ?? false, italic: style?.italic ?? false)
        }
        return EditorTheme(
            text: .init(color: text),
            insertionPoint: picked.cursor.map(color) ?? text,
            invisibles: .init(color: picked.whitespace.map(color) ?? text.withAlphaComponent(0.3)),
            background: background,
            lineHighlight: picked.lineHighlight.map(color)
                ?? (dark ? NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.06) : NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.04)),
            selection: picked.selection.map(color) ?? systemSelection,
            keywords: attribute(.keyword),
            commands: attribute(.command),
            types: attribute(.type),
            attributes: attribute(.attribute),
            variables: attribute(.variable),
            values: attribute(.value),
            numbers: attribute(.number),
            strings: attribute(.string),
            characters: attribute(.character),
            comments: attribute(.comment))
    }

    private static func color(_ rgba: RGBA) -> NSColor {
        NSColor(srgbRed: rgba.red, green: rgba.green, blue: rgba.blue, alpha: rgba.alpha)
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
