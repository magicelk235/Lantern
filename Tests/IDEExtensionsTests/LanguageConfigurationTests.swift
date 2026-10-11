import Foundation
import IDEExtensions
import Testing

@Suite struct LanguageConfigurationTests {
    typealias Pair = LanguageConfiguration.Pair

    @Test func pairsAreArraysOrObjectsAndAnythingElseIsLeftOut() throws {
        let folder = try TempFolder()
        let url = try folder.write("language-configuration.json", #"""
        {
            "comments": { "lineComment": "//", "blockComment": ["/*", "*/"] },
            "brackets": [["{", "}"], ["(", ")"], ["<"], "[]", ["", "]"]],
            // Objects with notIn, arrays, and entries that are neither.
            "autoClosingPairs": [
                { "open": "{", "close": "}" },
                { "open": "\"", "close": "\"", "notIn": ["string"] },
                ["(", ")"],
                { "open": "'" },
                42,
            ],
            "surroundingPairs": [["'", "'"], { "open": "`", "close": "`" }],
        }
        """#)
        let configuration = try LanguageConfiguration.load(url)
        #expect(configuration.lineComment == "//")
        #expect(configuration.blockComment == Pair(open: "/*", close: "*/"))
        #expect(configuration.brackets == [Pair(open: "{", close: "}"), Pair(open: "(", close: ")")])
        #expect(configuration.autoClosingPairs == [
            Pair(open: "{", close: "}"), Pair(open: "\"", close: "\""), Pair(open: "(", close: ")"),
        ])
        #expect(configuration.surroundingPairs == [Pair(open: "'", close: "'"), Pair(open: "`", close: "`")])
    }

    @Test func missingPairListsFallBackAsInVSCode() throws {
        let folder = try TempFolder()
        let url = try folder.write("a.json", #"""
        { "comments": { "lineComment": { "comment": "#", "noIndent": true } }, "brackets": [["[", "]"]] }
        """#)
        let configuration = try LanguageConfiguration.load(url)
        #expect(configuration.lineComment == "#")
        #expect(configuration.blockComment == nil)
        #expect(configuration.autoClosingPairs == [Pair(open: "[", close: "]")])
        #expect(configuration.surroundingPairs == [Pair(open: "[", close: "]")])
        // An empty list is a list: nothing auto-closes, so nothing surrounds either.
        let empty = try folder.write("b.json", #"{ "brackets": [["[", "]"]], "autoClosingPairs": [] }"#)
        #expect(try LanguageConfiguration.load(empty).surroundingPairs == [])
    }
}
