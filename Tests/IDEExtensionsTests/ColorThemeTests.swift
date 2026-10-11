import Foundation
import IDEExtensions
import Testing

@Suite struct ColorThemeTests {
    private func load(_ folder: TempFolder, _ file: String) throws -> ColorTheme {
        let path = folder.url.appending(path: file)
        return try ColorTheme.load(ThemeContribution(id: "x/\(file)", label: "Test", isDark: true, path: path))
    }

    @Test func anIncludedThemeComesFirstSoTheIncludingOneOverridesIt() throws {
        let folder = try TempFolder()
        try folder.write("themes/base.json", #"""
        {
            "colors": {
                "editor.background": "#000000", "editor.foreground": "#111111", "editorCursor.foreground": "#222222",
            },
            "tokenColors": [
                { "scope": "string", "settings": { "foreground": "#aa0000", "fontStyle": "bold" } },
                { "scope": "comment", "settings": { "foreground": "#777777" } },
            ],
        }
        """#)
        try folder.write("themes/main.json", #"""
        {
            "include": "./base.json",
            "colors": { "editor.background": "#ffffff", "editorCursor.foreground": "default" },
            "tokenColors": [{ "scope": "string", "settings": { "foreground": "#00aa00" } }],
        }
        """#)
        let theme = try load(folder, "themes/main.json")
        #expect(theme.background == RGBA(hex: "#ffffff"))
        #expect(theme.foreground == RGBA(hex: "#111111"))
        // "default" takes the included theme's color away.
        #expect(theme.cursor == nil)
        // Equally specific rules: the later one's color, and the font style only the earlier one sets.
        #expect(theme.style(forScope: "string.quoted") == ColorTheme.Style(color: RGBA(hex: "#00aa00"), bold: true))
        #expect(theme.style(forScope: "comment.line")?.color == RGBA(hex: "#777777"))
    }

    @Test func theMostSpecificSelectorWinsEachOfColorAndFontStyle() throws {
        let folder = try TempFolder()
        try folder.write("theme.json", #"""
        {
            "tokenColors": [
                { "scope": "keyword.control", "settings": { "foreground": "#0000ff" } },
                { "scope": "keyword", "settings": { "foreground": "#ff0000", "fontStyle": "italic bold" } },
                { "scope": ["string.quoted", "constant.numeric"], "settings": { "fontStyle": "italic" } },
                { "scope": "string, constant", "settings": { "foreground": "#00ff00" } },
                { "scope": "comment", "settings": { "foreground": "#888888", "fontStyle": "italic" } },
                { "scope": "comment.line", "settings": { "fontStyle": "" } },
                {
                    "scope": "source.swift string, -comment, meta.tag > string",
                    "settings": { "foreground": "#123456" },
                },
                { "scope": "entity.other.attribute-name", "settings": { "foreground": "#abcdef" } },
                { "scope": "variable", "settings": { "foreground": "not a color" } },
            ],
        }
        """#)
        let theme = try load(folder, "theme.json")
        // keyword.control beats keyword, which comes later; keyword's font style still applies.
        let blue = RGBA(hex: "#0000ff"), red = RGBA(hex: "#ff0000")
        #expect(theme.style(forScope: "keyword.control.swift") == .init(color: blue, bold: true, italic: true))
        #expect(theme.style(forScope: "keyword.other") == .init(color: red, bold: true, italic: true))
        // Whole segments only.
        #expect(theme.style(forScope: "keywords") == nil)
        #expect(theme.style(forScope: "key") == nil)
        #expect(theme.style(forScope: "string.quoted.double") == .init(color: RGBA(hex: "#00ff00"), italic: true))
        #expect(theme.style(forScope: "string.unquoted") == .init(color: RGBA(hex: "#00ff00")))
        #expect(theme.style(forScope: "constant.numeric.integer") == .init(color: RGBA(hex: "#00ff00"), italic: true))
        // An empty font style takes back the italics of a less specific rule.
        #expect(theme.style(forScope: "comment.line.double-slash") == .init(color: RGBA(hex: "#888888")))
        #expect(theme.style(forScope: "comment.block") == .init(color: RGBA(hex: "#888888"), italic: true))
        // Selectors with parent scopes or exclusions are not used; a hyphen inside a segment is part of it.
        #expect(theme.style(forScope: "string")?.color == RGBA(hex: "#00ff00"))
        #expect(theme.style(forScope: "entity.other.attribute-name.html")?.color == RGBA(hex: "#abcdef"))
        #expect(theme.style(forScope: "variable.other") == nil)
    }

    @Test func aCategoryTakesTheFirstOfItsScopesThatHasAColor() throws {
        let folder = try TempFolder()
        try folder.write("theme.json", #"""
        {
            "tokenColors": [
                { "scope": "keyword.control", "settings": { "fontStyle": "bold" } },
                { "scope": "storage.type", "settings": { "foreground": "#00ff00" } },
                { "scope": "constant", "settings": { "foreground": "#ff00ff", "fontStyle": "italic" } },
            ],
        }
        """#)
        let theme = try load(folder, "theme.json")
        // keyword.control has only a font style and keyword nothing, so storage.type styles keywords.
        #expect(theme.style(for: .keyword) == .init(color: RGBA(hex: "#00ff00")))
        #expect(theme.style(for: .number) == .init(color: RGBA(hex: "#ff00ff"), italic: true))
        #expect(theme.style(for: .comment) == nil)
    }

    @Test func aRuleWithoutScopeGivesTheEditorColorsTheThemeLacks() throws {
        let folder = try TempFolder()
        try folder.write("a.json", #"""
        {
            "tokenColors": [
                { "settings": { "foreground": "#eeeeee", "background": "#101010" } },
                { "scope": "string", "settings": { "foreground": "#00ff00" } },
            ],
        }
        """#)
        let a = try load(folder, "a.json")
        #expect(a.foreground == RGBA(hex: "#eeeeee"))
        #expect(a.background == RGBA(hex: "#101010"))
        #expect(a.style(forScope: "string")?.color == RGBA(hex: "#00ff00"))
        try folder.write("b.json", #"""
        {
            "colors": { "editor.foreground": "#222222" },
            "tokenColors": [{ "scope": "", "settings": { "foreground": "#eeeeee" } }],
        }
        """#)
        #expect(try load(folder, "b.json").foreground == RGBA(hex: "#222222"))
    }

    @Test func aTextMateThemeGivesTheEditorColorsInItsFirstSettings() throws {
        let folder = try TempFolder()
        try folder.write("Monokai.tmTheme", textMateTheme(#"""
            <dict>
                <key>settings</key>
                <dict>
                    <key>background</key><string>#272822</string>
                    <key>foreground</key><string>#F8F8F2</string>
                    <key>caret</key><string>#F8F8F0</string>
                    <key>selection</key><string>#49483E</string>
                    <key>lineHighlight</key><string>#3E3D32</string>
                    <key>invisibles</key><string>#3B3A32</string>
                </dict>
            </dict>
            <dict>
                <key>name</key><string>Comment</string>
                <key>scope</key><string>comment</string>
                <key>settings</key>
                <dict>
                    <key>foreground</key><string>#75715E</string>
                    <key>fontStyle</key><string>italic</string>
                </dict>
            </dict>
        """#))
        let theme = try load(folder, "Monokai.tmTheme")
        #expect(theme.background == RGBA(hex: "#272822"))
        #expect(theme.foreground == RGBA(hex: "#F8F8F2"))
        #expect(theme.cursor == RGBA(hex: "#F8F8F0"))
        #expect(theme.selection == RGBA(hex: "#49483E"))
        #expect(theme.lineHighlight == RGBA(hex: "#3E3D32"))
        #expect(theme.whitespace == RGBA(hex: "#3B3A32"))
        #expect(theme.style(for: .comment) == .init(color: RGBA(hex: "#75715E"), italic: true))
    }

    @Test func tokenColorsMayBeATextMateFileAndSettingsAreTheOldNameForThem() throws {
        let folder = try TempFolder()
        try folder.write("rules/syntax.tmTheme", textMateTheme(#"""
            <dict>
                <key>scope</key><string>string</string>
                <key>settings</key><dict><key>foreground</key><string>#00FF00</string></dict>
            </dict>
        """#))
        try folder.write("themes/a.json", #"""
        { "colors": { "editor.background": "#000000" }, "tokenColors": "../rules/syntax.tmTheme" }
        """#)
        let a = try load(folder, "themes/a.json")
        #expect(a.background == RGBA(hex: "#000000"))
        #expect(a.style(forScope: "string.quoted")?.color == RGBA(hex: "#00ff00"))
        try folder.write("b.json", #"""
        { "settings": [
            { "settings": { "background": "#123456", "caret": "#ff0000" } },
            { "scope": "comment", "settings": { "foreground": "#654321" } },
        ] }
        """#)
        let b = try load(folder, "b.json")
        #expect(b.background == RGBA(hex: "#123456"))
        #expect(b.cursor == RGBA(hex: "#ff0000"))
        #expect(b.style(forScope: "comment")?.color == RGBA(hex: "#654321"))
    }

    @Test func aThemeIncludingItselfFailsInsteadOfLooping() throws {
        let folder = try TempFolder()
        try folder.write("loop.json", #"{ "include": "./loop.json" }"#)
        #expect(throws: ExtensionError.self) { try load(folder, "loop.json") }
        #expect(throws: ExtensionError.self) { try load(folder, "missing.json") }
    }

    /// A TextMate theme property list whose `settings` array holds `entries`.
    private func textMateTheme(_ entries: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>name</key><string>Test</string>
            <key>settings</key>
            <array>
        \(entries)
            </array>
        </dict>
        </plist>
        """
    }
}
