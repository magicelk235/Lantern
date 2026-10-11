import Foundation
import IDEExtensions
import Testing

@Suite struct ExtensionManifestTests {
    @Test func stringsComeFromTheNLSFileAndPathsFromTheFolder() throws {
        let folder = try TempFolder()
        try folder.write("package.json", #"""
        {
            "name": "theme-dracula",
            "publisher": "Dracula-Theme",
            "displayName": "%displayName%",
            "description": "%description%",
            "version": "2.25.1",
            "contributes": {
                "themes": [
                    { "label": "%theme.dark%", "uiTheme": "vs-dark", "path": "./themes/dark.json" },
                    { "label": "Light", "uiTheme": "vs", "path": "themes/light.json" },
                    { "label": "Contrast", "uiTheme": "hc-black", "path": "./themes/../themes/dark.json" },
                    { "label": "%untranslated%", "uiTheme": "hc-light", "path": "./themes/light.json" },
                    { "label": "No file", "uiTheme": "vs-dark", "path": "./themes/missing.json" },
                    { "label": "A folder", "uiTheme": "vs-dark", "path": "./themes" },
                    { "label": "No path", "uiTheme": "vs-dark" },
                    { "label": "Light", "uiTheme": "vs", "path": "./themes/dark.json" },
                ],
                "snippets": [
                    { "language": "javascript", "path": "./snippets/js.code-snippets" },
                    { "path": "./snippets/js.code-snippets" },
                ],
                "languages": [
                    {
                        "id": "vue", "aliases": ["Vue", "vue"], "extensions": [".Vue"], "filenames": ["Vuefile"],
                        "configuration": "./language-configuration.json",
                    },
                    { "aliases": ["No id"] },
                    { "id": "bare" },
                    { "id": "markdown", "configuration": "./missing-configuration.json", "extensions": [".MD"] },
                ],
            },
        }
        """#)
        try folder.write("package.nls.json", #"""
        {
            "displayName": "Dracula Official",
            "description": { "message": "A dark theme", "comment": ["for translators"] },
            "theme.dark": "Dracula",
        }
        """#)
        for file in ["themes/dark.json", "themes/light.json", "snippets/js.code-snippets"] {
            try folder.write(file, "{}")
        }
        try folder.write("language-configuration.json", "{}")

        let installed = try ExtensionManifest.read(folder: folder.url)
        #expect(installed.id == "dracula-theme.theme-dracula")
        #expect(installed.publisher == "Dracula-Theme")
        #expect(installed.displayName == "Dracula Official")
        #expect(installed.summary == "A dark theme")
        #expect(installed.version == "2.25.1")
        // Missing files, folders and paths are left out; a second "Light" would have the first one's identifier.
        #expect(installed.themes.map(\.label) == ["Dracula", "Light", "Contrast", "%untranslated%"])
        #expect(installed.themes.first?.id == "dracula-theme.theme-dracula/Dracula")
        #expect(installed.themes.map(\.isDark) == [true, false, true, false])
        let path = { (file: String) in folder.url.appending(path: file).path(percentEncoded: false) }
        let dark = path("themes/dark.json"), light = path("themes/light.json")
        #expect(installed.themes.map { $0.path.path(percentEncoded: false) } == [dark, light, dark, light])
        #expect(installed.snippets.map(\.language) == ["javascript"])
        #expect(installed.snippets.first?.path.path(percentEncoded: false) == path("snippets/js.code-snippets"))
        #expect(installed.languages.map(\.id) == ["vue", "markdown"])
        let vue = try #require(installed.languages.first)
        #expect(vue.aliases == ["Vue", "vue"])
        #expect(vue.extensions == [".vue"])
        #expect(vue.filenames == ["Vuefile"])
        #expect(vue.configuration?.path(percentEncoded: false) == path("language-configuration.json"))
        #expect(installed.languages.last?.configuration == nil)
        #expect(installed.languages.last?.extensions == [".md"])
    }

    @Test func aFolderWithoutAManifestIsNotAnExtensionAndABrokenOneIsUnreadable() throws {
        let folder = try TempFolder()
        #expect(throws: ExtensionError.notAnExtension) { try ExtensionManifest.read(folder: folder.url) }
        try folder.write("package.json", #"{ "name": "#)
        #expect(throws: ExtensionError.unreadable("package.json")) { try ExtensionManifest.read(folder: folder.url) }
        // The identifier names a folder in the extensions folder, so it cannot lead out of it.
        try folder.write("package.json", #"{ "name": "../../escape", "publisher": "someone" }"#)
        #expect(throws: ExtensionError.unreadable("package.json")) { try ExtensionManifest.read(folder: folder.url) }
        try folder.write("package.json", #"{ "name": "fine", "publisher": ".hidden" }"#)
        #expect(throws: ExtensionError.unreadable("package.json")) { try ExtensionManifest.read(folder: folder.url) }
    }

    @Test func anExtensionOfOnlyCodeContributesNothing() throws {
        let folder = try TempFolder()
        try folder.write("package.json", #"""
        {
            "name": "runner", "publisher": "someone", "main": "./out/extension.js",
            "contributes": {
                "commands": [{ "command": "runner.run", "title": "Run" }],
                "languages": [{ "id": "bare" }],
            },
        }
        """#)
        let installed = try ExtensionManifest.read(folder: folder.url)
        #expect(installed.displayName == "runner")
        #expect(installed.summary == nil)
        #expect(!installed.contributesAnything)
    }
}
