import IDEEditorModel
import Testing

@Suite struct FinderNamingTests {
    private func name(_ name: String, folder: Bool = false, _ style: FinderNaming.Style, taken: Set<String> = []) -> String {
        FinderNaming.name(for: name, isDirectory: folder, style: style, isTaken: taken.contains)
    }

    @Test func duplicateAddsCopyBeforeTheExtensionAndCountsOn() {
        #expect(name("a.txt", .duplicate) == "a copy.txt")
        #expect(name("a.txt", .duplicate, taken: ["a copy.txt"]) == "a copy 2.txt")
        #expect(name("a.txt", .duplicate, taken: ["a copy.txt", "a copy 2.txt"]) == "a copy 3.txt")
        #expect(name("a copy.txt", .duplicate) == "a copy 2.txt")
        #expect(name("a copy 2.txt", .duplicate) == "a copy 3.txt")
    }

    @Test func foldersDotfilesAndBareNamesHaveNoExtension() {
        #expect(name("Sources.v2", folder: true, .duplicate) == "Sources.v2 copy")
        #expect(name(".gitignore", .duplicate) == ".gitignore copy")
        #expect(name("Makefile", .duplicate) == "Makefile copy")
        #expect(name("archive.tar.gz", .duplicate) == "archive.tar copy.gz")
    }

    @Test func keepBothNumbersFromTwo() {
        #expect(name("a.txt", .keepBoth) == "a 2.txt")
        #expect(name("a.txt", .keepBoth, taken: ["a 2.txt"]) == "a 3.txt")
        #expect(name("a 2.txt", .keepBoth) == "a 3.txt")
        #expect(name("docs", folder: true, .keepBoth) == "docs 2")
        #expect(name("2.txt", .keepBoth) == "2 2.txt")
    }
}
