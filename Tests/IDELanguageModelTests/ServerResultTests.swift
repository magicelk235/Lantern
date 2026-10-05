import Foundation
import IDELanguageModel
import LanguageServerProtocol
import Testing

@Suite struct HoverContentTests {
    @Test func markdownSplitsIntoCodeTextAndRules() {
        let hover = Hover(
            contents: .optionC(MarkupContent(
                kind: .markdown,
                value: "```swift\nfunc greet(_ name: String) -> String\n```\n\n---\n\nSays **hello**.\n\n```\nlet x = greet(\"a\")\n```\n")),
            range: nil)
        #expect(HoverBlock.blocks(of: hover) == [
            .code("func greet(_ name: String) -> String"), .rule, .markdown("Says **hello**."), .code("let x = greet(\"a\")"),
        ])
    }

    @Test func plainTextAndMarkedStringsKeepTheirKinds() {
        #expect(HoverBlock.blocks(of: Hover(contents: .optionC(MarkupContent(kind: .plaintext, value: "a *b*\n")), range: nil)) == [.plain("a *b*")])
        let marked = Hover(
            contents: .optionB([.optionB(LanguageStringPair(language: .swift, value: "var x: Int")), .optionA("The *x*.")]), range: nil)
        #expect(HoverBlock.blocks(of: marked) == [.code("var x: Int"), .markdown("The *x*.")])
        #expect(HoverBlock.blocks(of: Hover(contents: .optionC(MarkupContent(kind: .markdown, value: "  \n")), range: nil)).isEmpty)
    }
}

@Suite struct DefinitionTargetTests {
    private let range = LSPRange(start: Position(line: 3, character: 4), end: Position(line: 3, character: 9))

    @Test func everyResponseShapeGivesFilePaths() {
        let location = Location(uri: "file:///p/My%20App/a.swift", range: range)
        #expect(DefinitionTarget.targets(from: .optionA(location)) == [DefinitionTarget(path: "/p/My App/a.swift", range: range)])
        #expect(
            DefinitionTarget.targets(from: .optionB([location, Location(uri: "https://example.com/x", range: range), location]))
                == [DefinitionTarget(path: "/p/My App/a.swift", range: range)])
        let selection = LSPRange(start: Position(line: 3, character: 5), end: Position(line: 3, character: 6))
        let link = LocationLink(targetUri: "file:///p/%C3%A9.rs", targetRange: range, targetSelectionRange: selection)
        #expect(DefinitionTarget.targets(from: .optionC([link])) == [DefinitionTarget(path: "/p/é.rs", range: selection)])
        #expect(DefinitionTarget.targets(from: nil).isEmpty)
    }

    @Test func pathsAndURIsRoundTrip() {
        for path in ["/p/My App/main.swift", "/tmp/é#1/a?.ts", "/a/b%20c.py"] {
            let uri = DocumentURI.uri(forPath: path)
            #expect(uri.hasPrefix("file:///"))
            #expect(DocumentURI.path(of: uri) == path)
        }
        #expect(DocumentURI.path(of: "untitled:Untitled-1") == nil)
    }

    @Test func aTargetsRangeIsFoundInItsFilesText() {
        let target = DefinitionTarget(path: "/p/a.swift", range: LSPRange(start: Position(line: 1, character: 4), end: Position(line: 1, character: 9)))
        #expect(target.range(in: "import A\nfunc greet() {}\n") == NSRange(location: 13, length: 5))
        // An empty range (sourcekit-lsp's) selects the name it is at.
        let empty = DefinitionTarget(path: "/p/a.swift", range: LSPRange(start: Position(line: 1, character: 5), end: Position(line: 1, character: 5)))
        #expect(empty.range(in: "import A\nfunc greet_2() {}\n") == NSRange(location: 14, length: 7))
        #expect(empty.range(in: "import A\nfunc (\n") == NSRange(location: 14, length: 0))
    }
}

@Suite struct CompletionCandidateTests {
    @Test func snippetsBecomeTheirPlainText() {
        #expect(SnippetText.plain("greet(${1:name}, times: ${2:count})$0") == "greet(name, times: count)")
        #expect(SnippetText.plain("for ${1:x} in ${2:${3:items}.reversed()} {\n\t$0\n}") == "for x in items.reversed() {\n\t\n}")
        #expect(SnippetText.plain("${1|let,var|} a = \\$b \\} ${2}") == "let a = $b } ")
        // A `$` that starts nothing is text; `$5` is a tab stop; a variable is its default.
        #expect(SnippetText.plain("cost: $$5 ${TM_FILENAME:file}") == "cost: $ file")
    }

    @Test func itemsAreSortedAndKeepTheirEdits() throws {
        let edit = TextEdit(range: LSPRange(start: Position(line: 0, character: 4), end: Position(line: 0, character: 6)), newText: "greet(name:)")
        let response: CompletionResponse = .optionB(CompletionList(isIncomplete: false, items: [
            CompletionItem(label: "zeta", kind: .variable, sortText: "2"),
            CompletionItem(
                label: " greet(name:)", kind: .function, detail: "String", documentation: .optionB(MarkupContent(kind: .markdown, value: "Says hi.")),
                sortText: "1", filterText: "greet", insertText: "unused", insertTextFormat: .snippet, textEdit: .optionA(edit)),
            CompletionItem(label: "•alpha", kind: .keyword, deprecated: true, insertText: "alpha(${1:x})", insertTextFormat: .snippet),
        ]))
        let candidates = CompletionCandidate.candidates(from: response)
        #expect(candidates.map(\.label) == ["greet(name:)", "zeta", "alpha"])
        let greet = try #require(candidates.first)
        #expect(greet.insertText == "greet(name:)" && greet.replacing == edit.range && greet.filterText == "greet")
        #expect(greet.category == .function && greet.detail == "String" && greet.documentation == "Says hi.")
        #expect(candidates[2].insertText == "alpha(x)" && candidates[2].deprecated && candidates[2].category == .keyword)
    }

    @Test func filteringKeepsSubsequenceMatchesWithPrefixesFirst() {
        let candidates = ["format", "forEach", "isEmpty", "first", "isFolder"].map {
            CompletionCandidate(label: $0, category: .function, insertText: $0)
        }
        #expect(CompletionCandidate.filter(candidates, by: "fo").map(\.label) == ["format", "forEach", "isFolder"])
        #expect(CompletionCandidate.filter(candidates, by: "FE").map(\.label) == ["forEach", "isFolder"])
        #expect(CompletionCandidate.filter(candidates, by: "").count == candidates.count)
        #expect(CompletionCandidate.filter(candidates, by: "zz").isEmpty)
    }

    @Test func acceptingReplacesWhatWasTypedThenAddsTheOtherEditsLastFirst() {
        // "imp|" typed at the end of line 1; the server's range starts at the word, and it adds an import on line 0.
        let text = "import A\nlet x = imp" as NSString
        let lines = LineTable(text)
        let candidate = CompletionCandidate(
            label: "important", category: .function, insertText: "important()",
            replacing: LSPRange(start: Position(line: 1, character: 8), end: Position(line: 1, character: 11)),
            additionalEdits: [
                TextEdit(range: LSPRange(start: Position(line: 0, character: 8), end: Position(line: 0, character: 8)), newText: "\nimport B"),
                // Overlapping the completion: dropped.
                TextEdit(range: LSPRange(start: Position(line: 1, character: 9), end: Position(line: 1, character: 10)), newText: "?"),
            ])
        let edits = candidate.edits(replacingTypedTextFrom: 17, to: 20, lines: lines, in: text)
        #expect(edits.map(\.range) == [NSRange(location: 17, length: 3), NSRange(location: 8, length: 0)])
        #expect(edits.map(\.text) == ["important()", "\nimport B"])
        // Without a server range: from where the word started when the list was asked for.
        let plain = CompletionCandidate(label: "x", category: .variable, insertText: "xyz")
        #expect(plain.edits(replacingTypedTextFrom: 18, to: 20, lines: lines, in: text).map(\.range) == [NSRange(location: 18, length: 2)])
    }
}

@Suite struct ServerFeaturesTests {
    private func features(_ json: String) throws -> ServerFeatures {
        ServerFeatures(try JSONDecoder().decode(ServerCapabilities.self, from: Data(json.utf8)), name: "server")
    }

    @Test func syncFollowsTheServersCapabilities() throws {
        let numeric = try features(#"{"textDocumentSync": 2}"#)
        #expect(numeric.change == .incremental && numeric.openClose && !numeric.save && !numeric.saveIncludesText)
        let options = try features(#"{"textDocumentSync": {"openClose": true, "change": 1, "save": {"includeText": true}}}"#)
        #expect(options.change == .full && options.openClose && options.save && options.saveIncludesText)
        let none = try features("{}")
        #expect(none.change == TextDocumentSyncKind.none && !none.openClose && !none.hover && !none.definition && none.completionTriggers == nil)
    }

    @Test func featuresReadHoverDefinitionAndCompletion() throws {
        let all = try features(#"{"hoverProvider": true, "definitionProvider": {}, "completionProvider": {"triggerCharacters": [".", "::"]}}"#)
        #expect(all.hover && all.definition && all.completionTriggers == [".", "::"])
        #expect(try features(#"{"hoverProvider": false, "completionProvider": {}}"#).completionTriggers == [])
    }
}
