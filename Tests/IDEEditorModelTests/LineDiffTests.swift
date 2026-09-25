import IDEEditorModel
import Testing

@Suite struct LineDiffTests {
    @Test func equalTextsHaveNoHunks() {
        #expect(LineDiff.hunks(from: "a\nb\n", to: "a\nb\n").isEmpty)
    }

    @Test func changesComeWithContextRemovalsFirstAndLineNumbersOfBothSides() {
        let old = (1...10).map { "line \($0)" }.joined(separator: "\n")
        var newLines = (1...10).map { "line \($0)" }
        newLines[4] = "line five"
        newLines.insert("inserted", at: 8)
        let hunks = LineDiff.hunks(from: old, to: newLines.joined(separator: "\n"), context: 1)

        // Two changes 3 unchanged lines apart stay separate with one line of context.
        #expect(hunks.count == 2)
        #expect(hunks[0].lines.map(\.kind) == [.context, .removed, .inserted, .context])
        #expect(hunks[0].lines.map(\.text) == ["line 4", "line 5", "line five", "line 6"])
        #expect(hunks[0].lines[1].oldNumber == 5 && hunks[0].lines[1].newNumber == nil)
        #expect(hunks[0].lines[2].oldNumber == nil && hunks[0].lines[2].newNumber == 5)
        #expect(hunks[0].header == "@@ -4,3 +4,3 @@")
        #expect(hunks[1].lines.map(\.text) == ["line 8", "inserted", "line 9"])
        #expect(hunks[1].header == "@@ -8,2 +8,3 @@")
    }

    @Test func nearbyChangesMergeIntoOneHunk() {
        let hunks = LineDiff.hunks(from: "a\nb\nc\nd\ne\n", to: "A\nb\nc\nD\ne\n", context: 1)
        #expect(hunks.count == 1)
        #expect(hunks[0].lines.map(\.text) == ["a", "A", "b", "c", "d", "D", "e"])
    }

    @Test func textAddedToAnEmptyFileIsAllInserted() {
        let hunks = LineDiff.hunks(from: "", to: "x\ny")
        #expect(hunks.count == 1)
        #expect(hunks[0].lines.map(\.kind) == [.removed, .inserted, .inserted])
        #expect(hunks[0].lines.map(\.text) == ["", "x", "y"])
    }
}
