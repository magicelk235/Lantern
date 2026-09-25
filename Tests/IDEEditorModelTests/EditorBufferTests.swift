import Foundation
import IDEEditorModel
import IDEState
import Testing

private let path = "/w/app/main.swift"
private let original = TextSnapshot(text: "let a = 1\n")

/// A buffer and the text its editor shows, driven like the editor drives it.
private struct Editor {
    var buffer: EditorBuffer
    var text: String

    init(_ opening: EditorBuffer.Opening) throws {
        guard case .text(let buffer, let text) = opening else { throw Unexpected(opening: opening) }
        self.buffer = buffer
        self.text = text
    }

    mutating func type(_ text: String) {
        self.text = text
        buffer.textDidChange(utf16Count: text.utf16.count) { text }
    }

    mutating func diskChanged(_ disk: FileContents) -> EditorBuffer.DiskChange {
        let text = text
        let change = buffer.diskDidChange(disk, utf16Count: text.utf16.count) { text }
        if case .reload(let snapshot) = change { self.text = snapshot.text }
        return change
    }

    struct Unexpected: Error {
        var opening: EditorBuffer.Opening
    }
}

@Suite struct EditorBufferTests {
    @Test func dirtyIsADifferenceFromTheBaselineByContentNotByHistory() throws {
        var editor = try Editor(EditorBuffer.open(path: path, disk: .text(original), restored: nil))
        #expect(editor.text == original.text && !editor.buffer.isDirty)

        editor.type("let a = 12\n")
        #expect(editor.buffer.isDirty)
        // Same length, other text: only the hash can tell.
        editor.type("let b = 1\n")
        #expect(editor.buffer.isDirty)
        // Undoing back to the file's text is clean again.
        editor.type(original.text)
        #expect(!editor.buffer.isDirty)
    }

    @Test func savingMakesTheSavedTextTheBaselineAndItsEchoFromDiskChangesNothing() throws {
        var editor = try Editor(EditorBuffer.open(path: path, disk: .text(original), restored: nil))
        editor.type("let a = 2\n")
        let saved = TextSnapshot(text: editor.text)
        editor.buffer.didSave(saved)
        #expect(!editor.buffer.isDirty && editor.buffer.baseline.hash == saved.hash)

        #expect(editor.diskChanged(.text(saved)) == .none)
        #expect(editor.text == saved.text)
        // The text before the save is an edit now.
        editor.type(original.text)
        #expect(editor.buffer.isDirty)
    }

    @Test func revertShowsTheFileAndDropsTheEdits() throws {
        var editor = try Editor(EditorBuffer.open(path: path, disk: .text(original), restored: nil))
        editor.type("let a = 3\n")
        editor.buffer.reload(from: original)
        editor.text = original.text
        #expect(!editor.buffer.isDirty && editor.buffer.conflict == nil)
    }

    @Test func externalChangeReloadsACleanBufferSilently() throws {
        var editor = try Editor(EditorBuffer.open(path: path, disk: .text(original), restored: nil))
        let agentWrote = TextSnapshot(text: "let a = 1\nlet b = 2\n")
        #expect(editor.diskChanged(.text(agentWrote)) == .reload(agentWrote))
        #expect(editor.text == agentWrote.text && !editor.buffer.isDirty && editor.buffer.baseline.hash == agentWrote.hash)
    }

    @Test func externalChangeUnderEditsIsAConflictUntilTheUserDecides() throws {
        var editor = try Editor(EditorBuffer.open(path: path, disk: .text(original), restored: nil))
        editor.type("let mine = 1\n")
        let agentWrote = TextSnapshot(text: "let theirs = 1\n")
        #expect(editor.diskChanged(.text(agentWrote)) == .conflict)
        #expect(editor.text == "let mine = 1\n" && editor.buffer.isDirty && editor.buffer.conflict == agentWrote)

        // Keep mine: the agent's version becomes what the edits are measured against, and is no longer news.
        let text = editor.text
        editor.buffer.keepMine(utf16Count: text.utf16.count) { text }
        #expect(editor.buffer.conflict == nil && editor.buffer.isDirty && editor.buffer.baseline.hash == agentWrote.hash)
        #expect(editor.diskChanged(.text(agentWrote)) == .none)

        // A newer version conflicts again; reloading it drops the edits.
        let agentWroteAgain = TextSnapshot(text: "let theirs = 2\n")
        #expect(editor.diskChanged(.text(agentWroteAgain)) == .conflict)
        editor.buffer.reload(from: agentWroteAgain)
        #expect(!editor.buffer.isDirty && editor.buffer.conflict == nil && editor.buffer.baseline.hash == agentWroteAgain.hash)
    }

    @Test func conflictEndsByItselfWhenTheFileGoesBackOrCatchesUp() throws {
        var editor = try Editor(EditorBuffer.open(path: path, disk: .text(original), restored: nil))
        editor.type("let mine = 1\n")
        #expect(editor.diskChanged(.text(TextSnapshot(text: "other\n"))) == .conflict)
        // `git checkout` of the file puts the baseline back.
        #expect(editor.diskChanged(.text(original)) == .none)
        #expect(editor.buffer.conflict == nil && editor.buffer.isDirty)
        // The file now holds exactly the edits (saved by someone else).
        #expect(editor.diskChanged(.text(TextSnapshot(text: "let mine = 1\n"))) == .becameClean)
        #expect(!editor.buffer.isDirty)
    }

    @Test func deletionKeepsTheTextAndOnlyEditsMakeItUnsaved() throws {
        var clean = try Editor(EditorBuffer.open(path: path, disk: .text(original), restored: nil))
        #expect(clean.diskChanged(.missing) == .gone)
        #expect(clean.buffer.gone == .deleted && !clean.buffer.isDirty && clean.text == original.text)
        #expect(clean.diskChanged(.missing) == .none)
        // Back with the same bytes: as if nothing happened.
        #expect(clean.diskChanged(.text(original)) == .none)
        #expect(clean.buffer.gone == nil)

        var edited = try Editor(EditorBuffer.open(path: path, disk: .text(original), restored: nil))
        edited.type("let a = 4\n")
        #expect(edited.diskChanged(.missing) == .gone)
        #expect(edited.buffer.isDirty && edited.buffer.gone == .deleted)
        edited.buffer.didSave(TextSnapshot(text: edited.text))
        #expect(edited.buffer.gone == nil && !edited.buffer.isDirty)
    }

    @Test func fileTurningBinaryReplacesACleanBufferButEditsStay() throws {
        var clean = try Editor(EditorBuffer.open(path: path, disk: .text(original), restored: nil))
        #expect(clean.diskChanged(.unsupported(.binary)) == .unsupported(.binary))

        var edited = try Editor(EditorBuffer.open(path: path, disk: .text(original), restored: nil))
        edited.type("let a = 5\n")
        #expect(edited.diskChanged(.unsupported(.binary)) == .gone)
        #expect(edited.buffer.gone == .unsupported(.binary) && edited.buffer.isDirty)
        // A read error says nothing about the file.
        #expect(edited.diskChanged(.unsupported(.unreadable("Permission denied"))) == .none)
    }

    // MARK: - Hot-exit restore

    @Test func hotExitCopyComesBackAsTheSameUnsavedEdits() throws {
        var editor = try Editor(EditorBuffer.open(path: path, disk: .text(original), restored: nil))
        editor.type("let a = 6\n")
        let copy = editor.buffer.hotExitCopy(contents: editor.text)
        #expect(copy.path == path && copy.contents == "let a = 6\n" && copy.baselineHash == original.hash)

        let relaunched = try Editor(EditorBuffer.open(path: path, disk: .text(original), restored: copy))
        #expect(relaunched.text == "let a = 6\n" && relaunched.buffer.isDirty && relaunched.buffer.conflict == nil)
        #expect(relaunched.buffer.baseline == editor.buffer.baseline)
    }

    @Test func hotExitCopyWinsOverAFileThatChangedMeanwhileWhichBecomesAConflict() throws {
        let copy = DirtyBuffer(path: path, contents: "let unsaved = 1\n", baselineHash: original.hash)
        let agentWrote = TextSnapshot(text: "let agent = 1\n")
        var editor = try Editor(EditorBuffer.open(path: path, disk: .text(agentWrote), restored: copy))
        #expect(editor.text == "let unsaved = 1\n" && editor.buffer.isDirty)
        #expect(editor.buffer.conflict == agentWrote && editor.buffer.baseline.hash == original.hash)
        // After a relaunch only the baseline's hash is known, which still recognizes its text.
        editor.type(original.text)
        #expect(!editor.buffer.isDirty)
    }

    @Test func hotExitCopyMatchingTheFileNowIsClean() throws {
        let copy = DirtyBuffer(path: path, contents: "let saved = 1\n", baselineHash: original.hash)
        let editor = try Editor(EditorBuffer.open(path: path, disk: .text(TextSnapshot(text: "let saved = 1\n")), restored: copy))
        #expect(!editor.buffer.isDirty && editor.buffer.conflict == nil)
    }

    @Test func hotExitCopyOfAFileThatIsGoneOrUnreadableStillOpens() throws {
        let copy = DirtyBuffer(path: path, contents: "let kept = 1\n", baselineHash: original.hash)
        let deleted = try Editor(EditorBuffer.open(path: path, disk: .missing, restored: copy))
        #expect(deleted.text == "let kept = 1\n" && deleted.buffer.isDirty && deleted.buffer.gone == .deleted)

        let huge = try Editor(EditorBuffer.open(path: path, disk: .unsupported(.tooLarge(bytes: 20_000_000)), restored: copy))
        #expect(huge.buffer.isDirty && huge.buffer.gone == .unsupported(.tooLarge(bytes: 20_000_000)))

        let unreadable = try Editor(EditorBuffer.open(path: path, disk: .unsupported(.unreadable("EIO")), restored: copy))
        #expect(unreadable.buffer.isDirty && unreadable.buffer.gone == nil && unreadable.buffer.conflict == nil)
    }

    @Test func withoutACopyOnlyTextFilesOpen() {
        #expect(EditorBuffer.open(path: path, disk: .missing, restored: nil) == .missing)
        #expect(EditorBuffer.open(path: path, disk: .unsupported(.binary), restored: nil) == .unsupported(.binary))
    }

    @Test func copyOfAFileThatNeverExistedIsAlwaysUnsaved() throws {
        let copy = DirtyBuffer(path: path, contents: "", baselineHash: nil)
        var editor = try Editor(EditorBuffer.open(path: path, disk: .missing, restored: copy))
        editor.type("")
        #expect(editor.buffer.isDirty)
    }
}
