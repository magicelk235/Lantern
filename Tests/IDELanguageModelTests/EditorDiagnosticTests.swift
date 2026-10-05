import Foundation
import IDELanguageModel
import LanguageServerProtocol
import Testing

@Suite struct EditorDiagnosticTests {
    private func range(_ startLine: Int, _ startCharacter: Int, _ endLine: Int, _ endCharacter: Int) -> LSPRange {
        LSPRange(start: Position(line: startLine, character: startCharacter), end: Position(line: endLine, character: endCharacter))
    }

    @Test func diagnosticsMapToTextRangesSortedWithErrorsForMissingSeverities() {
        let text = "let a: Int = \"x\"\nprint(b)\n" as NSString
        let diagnostics = [
            Diagnostic(range: range(1, 6, 1, 7), severity: .warning, source: "sourcekitd", message: "unused"),
            Diagnostic(range: range(0, 13, 0, 16), code: .optionB("E1"), message: "cannot convert"),
            Diagnostic(range: range(1, 0, 1, 5), severity: .hint, message: "a hint"),
        ]
        let mapped = EditorDiagnostic.map(diagnostics, lines: LineTable(text), in: text)
        #expect(mapped.map(\.range) == [NSRange(location: 13, length: 3), NSRange(location: 17, length: 5), NSRange(location: 23, length: 1)])
        #expect(mapped.map(\.severity) == [.error, .hint, .warning])
        #expect(mapped[0].code == "E1" && mapped[2].source == "sourcekitd")
        #expect(DiagnosticCounts(mapped) == DiagnosticCounts(errors: 1, warnings: 1))
    }

    @Test func rangesOutsideTheTextAreClampedToIt() {
        let text = "ab\ncd" as NSString
        let mapped = EditorDiagnostic.map(
            [Diagnostic(range: range(1, 1, 7, 0), severity: .error, message: "past the end")], lines: LineTable(text), in: text)
        #expect(mapped.first?.range == NSRange(location: 4, length: 1))
    }

    @Test func aPublicationMapsItsDiagnosticsIntoTheTextItCameFor() {
        let text = "ab\ncd" as NSString
        let published = PublishedDiagnostics(
            path: "/p/a.swift", version: 3, diagnostics: [Diagnostic(range: range(1, 0, 1, 2), severity: .warning, message: "w")])
        #expect(published.editorDiagnostics(lines: LineTable(text), in: text)
            == [EditorDiagnostic(range: NSRange(location: 3, length: 2), severity: .warning, message: "w")])
        #expect(published.isOlder(than: 4) && !published.isOlder(than: 3))
        #expect(!PublishedDiagnostics(path: "/p/a.swift", version: nil, diagnostics: []).isOlder(than: 9))
    }

    @Test func anEmptyRangeIsUnderlinedOnTheCharacterAtItOrBeforeIt() {
        let text = "f(x\nab😀" as NSString
        let at = { (location: Int) in
            EditorDiagnostic(range: NSRange(location: location, length: 0), severity: .error, message: "m").underline(in: text)
        }
        #expect(at(1) == NSRange(location: 1, length: 1))
        // At a line break: the character before it.
        #expect(at(3) == NSRange(location: 2, length: 1))
        // At the end: the last character, a whole surrogate pair.
        #expect(at(text.length) == NSRange(location: 6, length: 2))
        #expect(EditorDiagnostic(range: NSRange(location: 0, length: 0), severity: .error, message: "m").underline(in: "") == nil)
        #expect(
            EditorDiagnostic(range: NSRange(location: 0, length: 2), severity: .error, message: "m").underline(in: text)
                == NSRange(location: 0, length: 2))
    }

    @Test func editsMoveDiagnosticsLikeMarkers() {
        let diagnostic = EditorDiagnostic(range: NSRange(location: 10, length: 4), severity: .error, message: "m")
        // After it: unchanged; before it: shifted.
        #expect(diagnostic.adjusted(replacing: NSRange(location: 20, length: 2), newLength: 9).range == NSRange(location: 10, length: 4))
        #expect(diagnostic.adjusted(replacing: NSRange(location: 2, length: 3), newLength: 1).range == NSRange(location: 8, length: 4))
        #expect(diagnostic.adjusted(replacing: NSRange(location: 14, length: 0), newLength: 3).range == NSRange(location: 10, length: 4))
        // Inside it: it grows or shrinks with the edit.
        #expect(diagnostic.adjusted(replacing: NSRange(location: 11, length: 1), newLength: 5).range == NSRange(location: 10, length: 8))
        // Over its start: it starts where the edit did and keeps its end.
        #expect(diagnostic.adjusted(replacing: NSRange(location: 8, length: 4), newLength: 1).range == NSRange(location: 8, length: 3))
        // Over its end: it ends where the inserted text does.
        #expect(diagnostic.adjusted(replacing: NSRange(location: 12, length: 5), newLength: 1).range == NSRange(location: 10, length: 3))
        // Over all of it: what was typed in its place.
        #expect(diagnostic.adjusted(replacing: NSRange(location: 9, length: 7), newLength: 2).range == NSRange(location: 9, length: 2))
    }
}
