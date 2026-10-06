import AppKit
import IDEState
import SwiftUI

/// The Files pane's context menu for one file or folder: open, Quick Look, a terminal there, Finder, the path, new
/// items, rename and Trash. The basics, in Finder's words.
struct FileItemMenu: View {
    let app: AppState
    let project: String
    let path: String
    let isDirectory: Bool

    private var folder: String { isDirectory ? path : (path as NSString).deletingLastPathComponent }

    var body: some View {
        if !isDirectory {
            Button("Open") { app.openEditor(path, in: project) }
            Button("Quick Look") { app.toggleQuickLook(path, in: project) }
        }
        Button("Open in Terminal") { app.newTerminal(in: folder) }
            .disabled(!app.connection.isConnected)
        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: path)]) }
        Divider()
        Button("Copy Path") { app.copyToPasteboard(path) }
        Button("Copy Relative Path") { app.copyToPasteboard(AppState.relativePath(path, in: project)) }
        Divider()
        Button("New File…") { app.newFile(in: folder, project: project) }
        Button("New Folder…") { app.newFolder(in: folder) }
        Divider()
        Button("Rename…") { app.renameItem(path, project: project) }
        Button("Move to Trash") { app.trashItem(path, project: project) }
    }
}

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
        let field = NSTextField(frame: NSRect(x: 0, y: 20, width: width, height: 24))
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
