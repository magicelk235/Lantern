import AppKit
import IDEEditorModel

extension AppState {
    /// `path` relative to `project`, or itself when it lies outside.
    static func relativePath(_ path: String, in project: String) -> String {
        path.hasPrefix(project + "/") ? String(path.dropFirst(project.count + 1)) : path
    }

    func copyToPasteboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    /// Creates an empty file named by the user in `folder` and opens it.
    func newFile(in folder: String, project: String) {
        guard let name = FileNamePrompt.ask(
            "New File", message: "Name of the file in “\(Self.projectName(folder))”:", button: "Create",
            placeholder: "untitled.txt", problem: { FileNamePrompt.problem(naming: $0, in: folder) })
        else { return }
        let path = (folder as NSString).appendingPathComponent(name)
        do {
            try Data().write(to: URL(filePath: path), options: .withoutOverwriting)
            editors.tree(for: project).setExpanded(folder, true)
            openEditor(path, in: project)
        } catch {
            alert = AlertMessage(title: "“\(name)” couldn’t be created.", message: FileNamePrompt.explanation(of: error, name: name))
        }
    }

    func newFolder(in folder: String) {
        guard let name = FileNamePrompt.ask(
            "New Folder", message: "Name of the folder in “\(Self.projectName(folder))”:", button: "Create",
            placeholder: "untitled folder", problem: { FileNamePrompt.problem(naming: $0, in: folder) })
        else { return }
        do {
            try FileManager.default.createDirectory(atPath: (folder as NSString).appendingPathComponent(name), withIntermediateDirectories: false)
        } catch {
            alert = AlertMessage(title: "“\(name)” couldn’t be created.", message: FileNamePrompt.explanation(of: error, name: name))
        }
    }

    /// Renames the file or folder in place. Its editor tab (or those of the files under the folder) follows it to the
    /// new name, unsaved edits and all; a rename that fails leaves everything as it was.
    func renameItem(_ path: String, project: String) {
        let current = (path as NSString).lastPathComponent
        let folder = (path as NSString).deletingLastPathComponent
        guard let name = FileNamePrompt.ask(
            "Rename “\(current)”", message: "Enter a new name:", button: "Rename", placeholder: current, initial: current,
            selectingBaseName: !Self.isFolder(path), problem: { FileNamePrompt.problem(naming: $0, in: folder, renaming: path) }),
            name != current
        else { return }
        let destination = (folder as NSString).appendingPathComponent(name)
        do {
            try FileManager.default.moveItem(atPath: path, toPath: destination)
        } catch {
            alert = AlertMessage(title: "“\(current)” couldn’t be renamed.", message: FileNamePrompt.explanation(of: error, name: name))
            return
        }
        editors.itemMoved(from: path, to: destination)
        moveEditors(from: path, to: destination)
    }

    /// Moves the file or folder to the Trash; its editor tabs close first, asking about unsaved edits.
    func trashItem(_ path: String, project: String) {
        Task {
            guard await closeEditors(under: path) else { return }
            let name = (path as NSString).lastPathComponent
            do {
                try FileManager.default.trashItem(at: URL(filePath: path), resultingItemURL: nil)
            } catch {
                alert = AlertMessage(title: "“\(name)” couldn’t be moved to the Trash.", message: FileNamePrompt.explanation(of: error, name: name))
            }
        }
    }

    // MARK: - Copy, paste, move and duplicate

    /// The items of `paths` no other of them holds: copying or moving a folder takes what is in it along.
    static func outermost(_ paths: [String]) -> [String] {
        var outermost: [String] = []
        for path in Set(paths).sorted() where !paths.contains(where: { path.hasPrefix($0 + "/") }) {
            outermost.append(path)
        }
        return outermost
    }

    /// The files and folders on the pasteboard, as Finder puts them there.
    static func pasteboardFiles(_ pasteboard: NSPasteboard = .general) -> [String] {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.map { $0.path(percentEncoded: false) }
    }

    /// Copy (and Cut): the items go on the pasteboard as file URLs, which Finder pastes too. After Cut, Paste moves them,
    /// until something else is copied.
    func putOnPasteboard(_ paths: [String], cut: Bool) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(Self.outermost(paths).map { URL(filePath: $0) as NSURL })
        filesOutlines.cut = cut ? FilesOutlines.Cut(changeCount: pasteboard.changeCount, paths: Self.outermost(paths)) : nil
    }

    /// Paste: the items on the pasteboard are copied into `folder`, or moved there when they were cut in Lantern or
    /// `moving` (Move Item Here, ⌥⌘V). Returns where they are now.
    func pasteFiles(into folder: String, moving: Bool, undoManager: UndoManager?) async -> [String] {
        let pasteboard = NSPasteboard.general
        let paths = Self.pasteboardFiles(pasteboard)
        guard !paths.isEmpty else { return [] }
        let wasCut = filesOutlines.cut.map { $0.changeCount == pasteboard.changeCount && $0.paths == paths } ?? false
        if moving || wasCut {
            if wasCut { filesOutlines.cut = nil }
            return moveItems(paths, into: folder, undoManager: undoManager)
        }
        return await copyItems(paths, into: folder, undoManager: undoManager)
    }

    /// Copies `sources` into `folder` off the main thread (each into its own folder for Duplicate, ⌘D, when `folder` is
    /// nil), named the way Finder names copies: one in its own folder is "name copy.ext", one whose name is taken where it
    /// goes "name 2.ext". Undo moves the copies to the Trash. Returns the copies.
    @discardableResult
    func copyItems(_ sources: [String], into folder: String?, undoManager: UndoManager?) async -> [String] {
        let done = await performCopies(copyPlan(sources, into: folder))
        registerUndoOfCopies(done, into: folder, undoManager: undoManager)
        return done.map(\.destination)
    }

    private func copyPlan(_ sources: [String], into folder: String?) -> [(source: String, destination: String)] {
        var plan: [(source: String, destination: String)] = []
        var chosen = Set<String>()
        for source in Self.outermost(sources) {
            let name = (source as NSString).lastPathComponent
            let parent = (source as NSString).deletingLastPathComponent
            let target = folder ?? parent
            if target == source || target.hasPrefix(source + "/") {
                alert = AlertMessage(title: "“\(name)” couldn’t be copied.", message: "A folder can’t be copied into itself.")
                continue
            }
            let isTaken = { (candidate: String) in
                let path = (target as NSString).appendingPathComponent(candidate)
                return chosen.contains(path.lowercased()) || FileManager.default.fileExists(atPath: path)
            }
            let inPlace = parent == target
            let copyName = inPlace || isTaken(name)
                ? FinderNaming.name(for: name, isDirectory: Self.isFolder(source), style: inPlace ? .duplicate : .keepBoth, isTaken: isTaken)
                : name
            let destination = (target as NSString).appendingPathComponent(copyName)
            chosen.insert(destination.lowercased())
            plan.append((source, destination))
        }
        return plan
    }

    /// Copies off the main thread; says which copies could not be made. Returns those made.
    private func performCopies(_ plan: [(source: String, destination: String)]) async -> [(source: String, destination: String)] {
        guard !plan.isEmpty else { return [] }
        let outcomes = await Task.detached(priority: .userInitiated) { [plan] in
            plan.map { step -> (any Error)? in
                do {
                    try FileManager.default.copyItem(atPath: step.source, toPath: step.destination)
                    return nil
                } catch {
                    return error
                }
            }
        }.value
        var done: [(source: String, destination: String)] = []
        for (step, failure) in zip(plan, outcomes) {
            if let failure {
                let name = (step.source as NSString).lastPathComponent
                alert = AlertMessage(title: "“\(name)” couldn’t be copied.", message: FileNamePrompt.explanation(of: failure, name: name))
            } else {
                done.append(step)
                editors.relist((step.destination as NSString).deletingLastPathComponent)
            }
        }
        return done
    }

    /// Undo moves the copies to the Trash; Redo copies again (its Undo registered at once, so that the other steps
    /// waiting to be redone stay).
    private func registerUndoOfCopies(_ copies: [(source: String, destination: String)], into folder: String?, undoManager: UndoManager?) {
        guard !copies.isEmpty, let undoManager else { return }
        registerFileUndo(undoManager, folder == nil ? "Duplicate" : "Copy") { app in
            for copy in copies {
                try? FileManager.default.trashItem(at: URL(filePath: copy.destination), resultingItemURL: nil)
                app.editors.relist((copy.destination as NSString).deletingLastPathComponent)
            }
            app.registerFileUndo(undoManager, folder == nil ? "Duplicate" : "Copy") { app in
                let plan = app.copyPlan(copies.map(\.source), into: folder)
                app.registerUndoOfCopies(plan, into: folder, undoManager: undoManager)
                Task { await app.performCopies(plan) }
            }
        }
    }

    /// Registers one step of Undo (of Redo, while undoing) for a file operation. One that finishes after an await is in
    /// no event's group: it gets a group of its own, never shared with the next operation.
    func registerFileUndo(_ undoManager: UndoManager, _ actionName: String, _ handler: @escaping @MainActor (AppState) -> Void) {
        let ownGroup = undoManager.groupingLevel == 0
        let groupsByEvent = undoManager.groupsByEvent
        if ownGroup {
            undoManager.groupsByEvent = false
            undoManager.beginUndoGrouping()
        }
        undoManager.registerUndo(withTarget: self) { app in
            MainActor.assumeIsolated { handler(app) }
        }
        undoManager.setActionName(actionName)
        if ownGroup {
            undoManager.endUndoGrouping()
            undoManager.groupsByEvent = groupsByEvent
        }
    }

    /// Moves `sources` into `folder` (a name taken there gets " 2"); their open editors follow, unsaved edits and all.
    /// Undo moves them back. Returns where they are now.
    @discardableResult
    func moveItems(_ sources: [String], into folder: String, undoManager: UndoManager?) -> [String] {
        var moves: [(from: String, to: String)] = []
        for source in Self.outermost(sources) where (source as NSString).deletingLastPathComponent != folder {
            let name = (source as NSString).lastPathComponent
            if folder == source || folder.hasPrefix(source + "/") {
                alert = AlertMessage(title: "“\(name)” couldn’t be moved.", message: "A folder can’t be moved into itself.")
                continue
            }
            let isTaken = { (candidate: String) in
                moves.contains { ($0.to as NSString).lastPathComponent.lowercased() == candidate.lowercased() }
                    || FileManager.default.fileExists(atPath: (folder as NSString).appendingPathComponent(candidate))
            }
            let target = isTaken(name) ? FinderNaming.name(for: name, isDirectory: Self.isFolder(source), style: .keepBoth, isTaken: isTaken) : name
            let destination = (folder as NSString).appendingPathComponent(target)
            do {
                try FileManager.default.moveItem(atPath: source, toPath: destination)
            } catch {
                alert = AlertMessage(title: "“\(name)” couldn’t be moved.", message: FileNamePrompt.explanation(of: error, name: name))
                continue
            }
            itemMoved(from: source, to: destination)
            moves.append((source, destination))
        }
        registerUndoOfMoves(moves, undoManager: undoManager, actionName: "Move")
        return moves.map(\.to)
    }

    /// `path` is at `destination` now: the navigators and the open editors follow it.
    private func itemMoved(from path: String, to destination: String) {
        editors.itemMoved(from: path, to: destination)
        moveEditors(from: path, to: destination)
        editors.relist((destination as NSString).deletingLastPathComponent)
    }

    /// Undo puts each item back where it was (and Redo moves it again), editors following.
    private func registerUndoOfMoves(_ moves: [(from: String, to: String)], undoManager: UndoManager?, actionName: String) {
        guard !moves.isEmpty, let undoManager else { return }
        let back = moves.reversed().map { (from: $0.to, to: $0.from) }
        registerFileUndo(undoManager, actionName) { app in
            var done: [(from: String, to: String)] = []
            for move in back {
                do {
                    try FileManager.default.moveItem(atPath: move.from, toPath: move.to)
                } catch {
                    let name = (move.from as NSString).lastPathComponent
                    app.alert = AlertMessage(title: "“\(name)” couldn’t be moved back.", message: FileNamePrompt.explanation(of: error, name: name))
                    continue
                }
                app.itemMoved(from: move.from, to: move.to)
                done.append(move)
            }
            app.registerUndoOfMoves(done, undoManager: undoManager, actionName: actionName)
        }
    }
}

/// A one-line name prompt (`NSAlert` with a text field), run modally. `problem` checks the name as it is typed: while
/// it gives a reason, the reason shows under the field and the default button is off, so an invalid name never
/// closes the prompt. Leading and trailing spaces are dropped.
@MainActor
enum FileNamePrompt {
    /// `selectingBaseName`: the field starts with the name selected up to its extension, as Finder renames.
    static func ask(
        _ title: String, message: String, button: String, placeholder: String, initial: String = "",
        selectingBaseName: Bool = false, problem: @escaping (String) -> String?
    ) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let confirm = alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        let width = 260.0
        let field = NameField(frame: NSRect(x: 0, y: 20, width: width, height: 24))
        field.placeholderString = placeholder
        field.stringValue = initial
        let reason = NSTextField(labelWithString: "")
        reason.frame = NSRect(x: 0, y: 0, width: width, height: 16)
        reason.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        reason.textColor = .systemRed
        reason.lineBreakMode = .byTruncatingMiddle
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 44))
        accessory.addSubview(field)
        accessory.addSubview(reason)
        alert.accessoryView = accessory
        alert.window.initialFirstResponder = field

        let validator = Validator {
            let name = Self.trimmed(field.stringValue)
            let found = name.isEmpty ? nil : problem(name)
            reason.stringValue = found ?? ""
            reason.toolTip = found
            confirm.isEnabled = !name.isEmpty && found == nil
        }
        validator.check()
        field.delegate = validator

        if selectingBaseName {
            let base = (initial as NSString).deletingPathExtension
            // Once the alert is up and the field has selected all of it.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    field.window?.makeFirstResponder(field)
                    field.currentEditor()?.selectedRange = NSRange(location: 0, length: (base as NSString).length)
                }
            }
        }
        let response = withExtendedLifetime(validator) { alert.runModal() }
        guard response == .alertFirstButtonReturn else { return nil }
        let name = trimmed(field.stringValue)
        return name.isEmpty || problem(name) != nil ? nil : name
    }

    /// The name without leading and trailing spaces.
    private static func trimmed(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespaces)
    }

    /// Checks the name on every keystroke, as the field's delegate.
    @MainActor
    private final class Validator: NSObject, NSTextFieldDelegate {
        let check: () -> Void

        init(_ check: @escaping () -> Void) {
            self.check = check
        }

        func controlTextDidChange(_ notification: Notification) {
            check()
        }
    }

    /// A text field that takes a file name as typed: no smart quotes or dashes, text replacements or spelling
    /// corrections, which would turn `"a--b"` into `“a–b”`.
    private final class NameField: NSTextField {
        override class var cellClass: AnyClass? {
            get { NameFieldCell.self }
            set {}
        }
    }

    private final class NameFieldCell: NSTextFieldCell {
        private var editor: NSTextView?

        override func fieldEditor(for controlView: NSView) -> NSTextView? {
            if let editor { return editor }
            let editor = NSTextView()
            editor.isFieldEditor = true
            editor.isAutomaticQuoteSubstitutionEnabled = false
            editor.isAutomaticDashSubstitutionEnabled = false
            editor.isAutomaticTextReplacementEnabled = false
            editor.isAutomaticSpellingCorrectionEnabled = false
            editor.isContinuousSpellCheckingEnabled = false
            editor.isAutomaticTextCompletionEnabled = false
            self.editor = editor
            return editor
        }
    }

    /// Why `name` cannot name a new item in `folder`, or `renaming` once renamed, in Finder's words; nil when it can.
    /// A rename that only changes the case of the name is fine on a volume that ignores case.
    static func problem(naming name: String, in folder: String, renaming original: String? = nil) -> String? {
        if name.contains("/") { return "Names can’t contain “/”." }
        if name.contains(":") { return "Names can’t contain “:”." }
        if name == "." || name == ".." { return "The name “\(name)” is reserved by the system." }
        if name.utf8.count > 255 { return "The name is too long." }
        let path = (folder as NSString).appendingPathComponent(name)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return nil }
        if let original, isSameItem(original, path) { return nil }
        return isDirectory.boolValue ? "A folder named “\(name)” already exists." : "A file named “\(name)” already exists."
    }

    /// Both paths name the same file (they differ in case only, on a volume that ignores case).
    private static func isSameItem(_ first: String, _ second: String) -> Bool {
        let keys: Set<URLResourceKey> = [.fileResourceIdentifierKey]
        guard let one = try? URL(filePath: first).resourceValues(forKeys: keys).fileResourceIdentifier,
              let other = try? URL(filePath: second).resourceValues(forKeys: keys).fileResourceIdentifier
        else { return false }
        return one.isEqual(other)
    }

    /// What went wrong creating, renaming or trashing `name`, in plain words rather than Cocoa's sentence about where
    /// it could not be moved.
    static func explanation(of error: any Error, name: String) -> String {
        let fallback = (error as NSError).localizedFailureReason ?? error.localizedDescription
        guard let code = (error as? CocoaError)?.code else { return fallback }
        switch code {
        case .fileWriteFileExists: return "An item named “\(name)” already exists."
        case .fileWriteNoPermission, .fileReadNoPermission: return "You don’t have permission to change this folder."
        case .fileWriteVolumeReadOnly: return "The disk is read-only."
        case .fileWriteOutOfSpace: return "The disk is full."
        case .fileNoSuchFile, .fileReadNoSuchFile: return "The item is no longer there."
        default: return fallback
        }
    }
}
