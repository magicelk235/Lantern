import Foundation
import IDELanguageModel
import LanguageServerProtocol
import Testing

@Suite struct DocumentSyncTests {
    private let path = "/w/My App/main.swift"

    /// Applies `edit` to `text` the way the editor's text storage reports it: the range replaced in the text before,
    /// and the text after.
    private func apply(
        _ range: NSRange, _ replacement: String, to text: NSMutableString, _ document: inout DocumentSync, kind: TextDocumentSyncKind
    ) -> DidChangeTextDocumentParams? {
        text.replaceCharacters(in: range, with: replacement)
        return document.didReplace(range, newLength: (replacement as NSString).length, in: text, sync: kind)
    }

    @Test func openingSendsTheWholeTextAsVersionOne() {
        let document = DocumentSync(path: path, languageId: "swift", text: "let a = 1\n")
        let params = document.openParams(text: "let a = 1\n")
        #expect(params.textDocument.uri == "file:///w/My%20App/main.swift")
        #expect(params.textDocument.languageId == "swift")
        #expect(params.textDocument.version == 1)
        #expect(params.textDocument.text == "let a = 1\n")
    }

    @Test func incrementalChangesAreRangesInTheTextBeforeEachEdit() throws {
        let text = NSMutableString(string: "let a = 1\nlet b = 2\n")
        var document = DocumentSync(path: path, languageId: "swift", text: text)

        let first = try #require(apply(NSRange(location: 18, length: 1), "42", to: text, &document, kind: .incremental))
        #expect(first.textDocument.version == 2)
        #expect(first.contentChanges == [
            TextDocumentContentChangeEvent(
                range: LSPRange(start: Position(line: 1, character: 8), end: Position(line: 1, character: 9)), rangeLength: 1,
                text: "42"),
        ])

        // A line break typed at the start of line 1, then text after it: positions follow the previous edits.
        let second = try #require(apply(NSRange(location: 10, length: 0), "\n", to: text, &document, kind: .incremental))
        let third = try #require(apply(NSRange(location: 11, length: 0), "x", to: text, &document, kind: .incremental))
        #expect(second.contentChanges.first?.range == LSPRange(start: Position(line: 1, character: 0), end: Position(line: 1, character: 0)))
        #expect(third.contentChanges.first?.range == LSPRange(start: Position(line: 2, character: 0), end: Position(line: 2, character: 0)))
        #expect(third.textDocument.version == 4)
        #expect(document.lines == LineTable(text))
    }

    @Test func fullSyncSendsTheWholeTextAndNoneSendsNothing() throws {
        let text = NSMutableString(string: "a\nb")
        var document = DocumentSync(path: path, languageId: "swift", text: text)
        let full = try #require(apply(NSRange(location: 0, length: 1), "c", to: text, &document, kind: .full))
        #expect(full.contentChanges == [TextDocumentContentChangeEvent(range: nil, rangeLength: nil, text: "c\nb")])
        #expect(apply(NSRange(location: 0, length: 1), "d", to: text, &document, kind: .none) == nil)
        // Positions still follow the text when nothing is sent.
        #expect(document.lines == LineTable(text))
    }

    @Test func changesGoOutAsTheServerSyncsOnceItHasTheDocumentOpen() throws {
        let text = NSMutableString(string: "a\nb")
        var document = DocumentSync(path: path, languageId: "swift", text: text)
        let incremental = ServerFeatures(
            try JSONDecoder().decode(ServerCapabilities.self, from: Data(#"{"textDocumentSync": 2}"#.utf8)), name: "s")
        let withoutOpen = ServerFeatures(
            try JSONDecoder().decode(ServerCapabilities.self, from: Data(#"{"textDocumentSync": {"change": 2}}"#.utf8)), name: "s")
        text.replaceCharacters(in: NSRange(location: 0, length: 0), with: "x")
        let withoutServer = document.didReplace(NSRange(location: 0, length: 0), newLength: 1, in: text, features: nil)
        #expect(withoutServer == nil)
        text.replaceCharacters(in: NSRange(location: 0, length: 0), with: "y")
        let notOpened = document.didReplace(NSRange(location: 0, length: 0), newLength: 1, in: text, features: withoutOpen)
        #expect(notOpened == nil)
        text.replaceCharacters(in: NSRange(location: 0, length: 0), with: "z")
        let change = document.didReplace(NSRange(location: 0, length: 0), newLength: 1, in: text, features: incremental)
        let sent = try #require(change)
        #expect(sent.textDocument.version == 2 && sent.contentChanges.first?.text == "z")
        #expect(document.lines == LineTable(text))
    }
}
