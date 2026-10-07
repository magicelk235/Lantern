import IDEEditorModel
import Testing

@Suite struct LanguageNameTests {
    @Test func languagesGoByTheirOwnSpelling() {
        #expect(LanguageName.display(id: "typescript") == "TypeScript")
        #expect(LanguageName.display(id: "tsx") == "TSX")
        #expect(LanguageName.display(id: "jsx") == "JSX")
        #expect(LanguageName.display(id: "javascript") == "JavaScript")
        #expect(LanguageName.display(id: "yaml") == "YAML")
        #expect(LanguageName.display(id: "json") == "JSON")
        #expect(LanguageName.display(id: "cpp") == "C++")
        #expect(LanguageName.display(id: "objc") == "Objective-C")
        #expect(LanguageName.display(id: "markdown") == "Markdown")
        #expect(LanguageName.display(id: "plainText") == "Plain Text")
    }

    @Test func anUnknownLanguageIsCapitalized() {
        #expect(LanguageName.display(id: "fortran") == "Fortran")
    }
}
