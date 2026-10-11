import Foundation

/// The kinds of highlighted text the editor's theme has a style for (CodeEditSourceEditor's `EditorTheme`), each with
/// the TextMate scopes a VS Code theme colors it by.
public enum SyntaxCategory: String, CaseIterable, Sendable {
    case keyword, command, type, attribute, variable, value, number, string, character, comment

    /// The scopes tried in order: the first the theme gives a color is the category's style.
    public var scopes: [String] {
        switch self {
        case .keyword: ["keyword.control", "keyword", "storage.type", "storage.modifier"]
        case .command: ["entity.name.function", "support.function"]
        case .type: ["entity.name.type", "support.type", "entity.name.class", "storage.type"]
        case .attribute: ["entity.other.attribute-name", "meta.attribute", "storage.type.annotation"]
        case .variable: ["variable.other", "variable", "meta.definition.variable.name"]
        case .value: ["constant.language", "support.constant", "constant"]
        case .number: ["constant.numeric"]
        case .string: ["string"]
        case .character: ["constant.character", "constant.character.escape"]
        case .comment: ["comment"]
        }
    }
}

/// A VS Code color theme as the editor draws it: the editor's colors, and the style of each TextMate scope.
public struct ColorTheme: Sendable, Equatable {
    /// How text of a scope is drawn.
    public struct Style: Sendable, Equatable {
        /// The text color; nil leaves the theme's foreground.
        public var color: RGBA?
        public var bold: Bool
        public var italic: Bool

        public init(color: RGBA? = nil, bold: Bool = false, italic: Bool = false) {
            self.color = color
            self.bold = bold
            self.italic = italic
        }
    }

    /// The theme's label.
    public let name: String
    public let isDark: Bool
    /// `editor.background`, else the background of a token rule without a scope.
    public let background: RGBA?
    /// `editor.foreground`, else the foreground of a token rule without a scope.
    public let foreground: RGBA?
    /// `editorCursor.foreground`.
    public let cursor: RGBA?
    /// `editor.selectionBackground`.
    public let selection: RGBA?
    /// `editor.lineHighlightBackground`.
    public let lineHighlight: RGBA?
    /// `editorWhitespace.foreground`.
    public let whitespace: RGBA?
    /// The token rules in the order the theme gives them, those of the themes it includes first.
    private let rules: [TokenRule]

    /// Reads the theme file of `contribution`, the way VS Code does.
    ///
    /// A JSON theme's `include` (a path relative to it, which may include another in turn) is read first, so its
    /// colors are overridden by the including theme's and its token rules come before the including theme's. Its
    /// `colors` give the editor's colors, and its `tokenColors` the rules: an array of them, or the path of a TextMate
    /// theme or JSON file holding them. A JSON theme with `settings` instead, or a TextMate theme (any file but
    /// `.json`), has the rules there, the first without a scope giving the editor's colors (`background`, `foreground`,
    /// `caret`, `selection`, `lineHighlight`, `invisibles`). Throws when a file cannot be read or is not a theme.
    public static func load(_ contribution: ThemeContribution) throws -> ColorTheme {
        var reader = ThemeReader()
        try reader.readTheme(contribution.path)
        let colors = reader.colors
        return ColorTheme(
            name: contribution.label,
            isDark: contribution.isDark,
            background: colors["editor.background"] ?? reader.defaultBackground,
            foreground: colors["editor.foreground"] ?? reader.defaultForeground,
            cursor: colors["editorCursor.foreground"],
            selection: colors["editor.selectionBackground"],
            lineHighlight: colors["editor.lineHighlightBackground"],
            whitespace: colors["editorWhitespace.foreground"],
            rules: reader.rules)
    }

    /// The style of text of `scope` (`string.quoted.double.swift`); nil when no rule applies to it.
    ///
    /// A rule applies when one of its selectors is the scope or a prefix of it in whole dot-separated segments
    /// (`string` applies to `string.quoted`, not to `stringy`). The color and the font style each come from the most
    /// specific rule that sets them, the one whose selector has the most segments, and of equally specific ones the
    /// later, as in VS Code: a `string.quoted` rule setting only italics keeps the color of a `string` one. Selectors
    /// naming parent scopes (`meta.tag string`) or excluding some (`-comment`) are not used.
    public func style(forScope scope: String) -> Style? {
        let segments = scope.split(separator: ".")
        var color: (specificity: Int, value: RGBA)?
        var fontStyle: (specificity: Int, value: FontStyle)?
        for rule in rules {
            guard let specificity = rule.specificity(for: segments) else { continue }
            if let value = rule.color, specificity >= color?.specificity ?? 0 {
                color = (specificity, value)
            }
            if let value = rule.fontStyle, specificity >= fontStyle?.specificity ?? 0 {
                fontStyle = (specificity, value)
            }
        }
        guard color != nil || fontStyle != nil else { return nil }
        return Style(
            color: color?.value, bold: fontStyle?.value.bold ?? false, italic: fontStyle?.value.italic ?? false)
    }

    /// The style of the first of `category`'s scopes the theme gives a color.
    public func style(for category: SyntaxCategory) -> Style? {
        for scope in category.scopes {
            if let style = style(forScope: scope), style.color != nil { return style }
        }
        return nil
    }
}

/// One `tokenColors` entry: the selectors it applies to and what it sets.
private struct TokenRule: Sendable, Equatable {
    /// Each selector's dot-separated segments.
    let selectors: [[String]]
    let color: RGBA?
    /// Bold and italic, when the rule sets a font style (an empty one sets neither).
    let fontStyle: FontStyle?

    /// The number of segments of the longest selector that is `scope` or a prefix of it; nil when none is.
    func specificity(for scope: [Substring]) -> Int? {
        selectors
            .filter { $0.count <= scope.count && zip($0, scope).allSatisfy { $0 == $1 } }
            .map(\.count)
            .max()
    }
}

private struct FontStyle: Sendable, Equatable {
    var bold: Bool
    var italic: Bool

    /// A `fontStyle` setting: words among `bold`, `italic`, `underline` and `strikethrough`.
    init(_ words: String) {
        let words = words.split(whereSeparator: \.isWhitespace)
        bold = words.contains("bold")
        italic = words.contains("italic")
    }
}

/// What a theme's files add up to, read in VS Code's order.
private struct ThemeReader {
    var colors: [String: RGBA] = [:]
    var rules: [TokenRule] = []
    /// The colors of the last token rule without a scope, for the editor colors the theme does not set.
    var defaultForeground: RGBA?
    var defaultBackground: RGBA?

    /// The editor colors set by a TextMate theme's rule without a scope: the setting, and the VS Code color it is.
    private static let editorSettings = [
        ("background", "editor.background"), ("foreground", "editor.foreground"),
        ("caret", "editorCursor.foreground"), ("selection", "editor.selectionBackground"),
        ("lineHighlight", "editor.lineHighlightBackground"), ("invisibles", "editorWhitespace.foreground"),
    ]

    /// Reads the theme file at `url`, `depth` includes down from the theme itself: a VS Code JSON theme, or else a
    /// TextMate theme.
    mutating func readTheme(_ url: URL, depth: Int = 0) throws {
        guard depth < 16 else { throw ExtensionError.unreadable(url.lastPathComponent) }
        guard url.pathExtension.lowercased() == "json" else { return try readTokenFile(url) }
        guard let data = try? Data(contentsOf: url),
              let theme = (try? JSONC.object(from: data)) as? [String: Any] else {
            throw ExtensionError.unreadable(url.lastPathComponent)
        }
        if let include = theme["include"] as? String {
            try readTheme(Self.file(include, nextTo: url), depth: depth + 1)
        }
        if let settings = theme["settings"] as? [Any] {
            readSettings(settings)
            return
        }
        for (key, value) in theme["colors"] as? [String: Any] ?? [:] {
            guard let hex = value as? String else { continue }
            if hex == "default" {
                colors[key] = nil
            } else if let color = RGBA(hex: hex) {
                colors[key] = color
            }
        }
        switch theme["tokenColors"] {
        case let entries as [Any]: readTokenColors(entries)
        case let path as String: try readTokenFile(Self.file(path, nextTo: url))
        default: break
        }
    }

    /// A file of token rules, as `tokenColors` may name one: a TextMate theme (a property list whose `settings` are
    /// the rules), or JSON that is an array of rules or a theme with `settings` or `tokenColors`.
    mutating func readTokenFile(_ url: URL) throws {
        guard let data = try? Data(contentsOf: url) else { throw ExtensionError.unreadable(url.lastPathComponent) }
        var object: Any?
        if url.pathExtension.lowercased() != "json" {
            object = try? PropertyListSerialization.propertyList(from: data, format: nil)
        }
        if object == nil { object = try? JSONC.object(from: data) }
        switch object {
        case let entries as [Any]:
            readTokenColors(entries)
        case let theme as [String: Any] where theme["settings"] is [Any]:
            readSettings(theme["settings"] as? [Any] ?? [])
        case let theme as [String: Any] where theme["tokenColors"] is [Any]:
            readTokenColors(theme["tokenColors"] as? [Any] ?? [])
        default:
            throw ExtensionError.unreadable(url.lastPathComponent)
        }
    }

    /// The rules of a TextMate theme (or of a JSON theme's `settings`): those without a scope set the editor's colors.
    mutating func readSettings(_ entries: [Any]) {
        for case let entry as [String: Any] in entries where Self.hasNoScope(entry) {
            let settings = entry["settings"] as? [String: Any] ?? [:]
            for (setting, key) in Self.editorSettings {
                if let color = (settings[setting] as? String).flatMap(RGBA.init(hex:)) { colors[key] = color }
            }
        }
        readTokenColors(entries)
    }

    /// `tokenColors` rules: a rule without a scope only gives the foreground and background the editor colors lack.
    mutating func readTokenColors(_ entries: [Any]) {
        for case let entry as [String: Any] in entries {
            guard let settings = entry["settings"] as? [String: Any] else { continue }
            let color = (settings["foreground"] as? String).flatMap(RGBA.init(hex:))
            if Self.hasNoScope(entry) {
                if let color { defaultForeground = color }
                if let background = (settings["background"] as? String).flatMap(RGBA.init(hex:)) {
                    defaultBackground = background
                }
                continue
            }
            let selectors = Self.selectors(entry["scope"])
            let fontStyle = (settings["fontStyle"] as? String).map(FontStyle.init)
            guard !selectors.isEmpty, color != nil || fontStyle != nil else { continue }
            rules.append(TokenRule(selectors: selectors, color: color, fontStyle: fontStyle))
        }
    }

    /// Whether a rule has no scope at all, which makes it the rule for all text.
    private static func hasNoScope(_ entry: [String: Any]) -> Bool {
        switch entry["scope"] {
        case nil, is NSNull: true
        case let scope as String: scope.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        default: false
        }
    }

    /// The selectors of a rule's `scope`, a string of comma-separated selectors or an array of them, each as its
    /// segments; those with parent scopes or exclusions are left out.
    private static func selectors(_ scope: Any?) -> [[String]] {
        let written: [String] = switch scope {
        case let text as String: text.components(separatedBy: ",")
        case let list as [Any]: list.compactMap { $0 as? String }.flatMap { $0.components(separatedBy: ",") }
        default: []
        }
        return written.compactMap { selector in
            let selector = selector.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !selector.isEmpty, !selector.hasPrefix("-"), !selector.contains(where: \.isWhitespace) else {
                return nil
            }
            return selector.split(separator: ".").map(String.init)
        }
    }

    private static func file(_ path: String, nextTo url: URL) -> URL {
        url.deletingLastPathComponent().appending(path: path, directoryHint: .notDirectory).standardized
    }
}
