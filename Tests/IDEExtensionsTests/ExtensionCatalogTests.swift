import Foundation
import IDEExtensions
import Testing

@Suite struct ExtensionCatalogTests {
    private func language(
        _ id: String, extensions: [String] = [], filenames: [String] = [], aliases: [String] = [],
        configuration: URL? = nil
    ) -> LanguageContribution {
        LanguageContribution(
            id: id, aliases: aliases, extensions: extensions, filenames: filenames, configuration: configuration)
    }

    private func installed(
        _ id: String, languages: [LanguageContribution], snippets: [SnippetContribution] = []
    ) -> InstalledExtension {
        InstalledExtension(
            id: id, publisher: "p", name: id, displayName: id, version: "1.0.0", summary: nil,
            folder: URL(filePath: "/extensions/\(id)", directoryHint: .isDirectory), themes: [], snippets: snippets,
            languages: languages)
    }

    @Test func aFileGoesByItsWholeNameFirstThenByItsLongestEnding() {
        let catalog = ExtensionCatalog([
            installed("a.json", languages: [language("json", extensions: [".json"])]),
            installed("b.typescript", languages: [
                language("typescript", extensions: [".ts"]), language("typescript-declarations", extensions: [".d.ts"]),
            ]),
            installed("c.make", languages: [language("makefile", extensions: [".mk"], filenames: ["Makefile"])]),
            installed("d.npm", languages: [language("package-json", filenames: ["package.json"])]),
            installed("e.other", languages: [language("other-typescript", extensions: [".ts"])]),
        ])
        // A name listed later wins over an ending listed earlier.
        #expect(catalog.language(forPath: "/p/package.json")?.id == "package-json")
        #expect(catalog.language(forPath: "/p/config.json")?.id == "json")
        #expect(catalog.language(forPath: "/p/types.d.ts")?.id == "typescript-declarations")
        // Endings in any case; of two extensions listing the same ending, the first.
        #expect(catalog.language(forPath: "/p/MAIN.TS")?.id == "typescript")
        #expect(catalog.language(forPath: "/p/Makefile")?.id == "makefile")
        // Names in their case only.
        #expect(catalog.language(forPath: "/p/makefile") == nil)
        #expect(catalog.language(forPath: "/p/README") == nil)
    }

    @Test func snippetsAreGatheredAndTheFirstConfigurationAndNameThatAreThereWin() throws {
        let folder = try TempFolder()
        let first = try folder.write("one.json", #"{ "B": { "prefix": "b", "body": "b" } }"#)
        let second = try folder.write("two.json", #"{ "A": { "prefix": "a", "body": "a" } }"#)
        let broken = try folder.write("broken.json", "{")
        let dashes = try folder.write("dashes.json", #"{ "comments": { "lineComment": "--" } }"#)
        let hash = try folder.write("hash.json", ##"{ "comments": { "lineComment": "#" } }"##)
        let catalog = ExtensionCatalog([
            installed(
                "x.one",
                languages: [
                    language("lua", configuration: folder.url.appending(path: "missing.json")),
                    language("lua", aliases: ["Lua", "lua"], configuration: dashes),
                ],
                snippets: [.init(language: "lua", path: first), .init(language: "lua", path: broken)]),
            installed(
                "y.two", languages: [language("lua", aliases: ["LUA"], configuration: hash)],
                snippets: [SnippetContribution(language: "lua", path: second)]),
        ])
        #expect(catalog.snippets(forLanguage: "lua").map(\.name) == ["A", "B"])
        #expect(catalog.snippets(forLanguage: "python").isEmpty)
        #expect(catalog.configuration(forLanguage: "lua")?.lineComment == "--")
        #expect(catalog.configuration(forLanguage: "python") == nil)
        #expect(catalog.displayName(forLanguage: "lua") == "Lua")
        #expect(catalog.displayName(forLanguage: "python") == nil)
    }

    @Test func treeSitterLanguagesHaveTheirVSCodeIdentifiers() {
        let cases: [(String, String?)] = [
            ("bash", "shellscript"), ("cSharp", "csharp"), ("goMod", "go.mod"), ("jsx", "javascriptreact"),
            ("tsx", "typescriptreact"), ("objc", "objective-c"), ("swift", "swift"),
            ("plainText", nil), ("markdownInline", nil), ("jsdoc", nil),
        ]
        for (treeSitter, vscode) in cases {
            #expect(ExtensionCatalog.languageId(treeSitterId: treeSitter) == vscode, "\(treeSitter)")
        }
    }
}
