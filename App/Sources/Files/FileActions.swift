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
        guard let name = FileNamePrompt.ask("New File", message: "Name of the file in \(Self.projectName(folder)):", placeholder: "untitled.txt") else { return }
        let path = (folder as NSString).appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: path) else {
            alert = AlertMessage(title: "Could not create the file", message: "\(name) already exists.")
            return
        }
        do {
            try Data().write(to: URL(filePath: path), options: .withoutOverwriting)
            editors.tree(for: project).setExpanded(folder, true)
            openEditor(path, in: project)
        } catch {
            alert = AlertMessage(title: "Could not create the file", message: error.localizedDescription)
        }
    }

    func newFolder(in folder: String) {
        guard let name = FileNamePrompt.ask("New Folder", message: "Name of the folder in \(Self.projectName(folder)):", placeholder: "untitled folder") else { return }
        do {
            try FileManager.default.createDirectory(atPath: (folder as NSString).appendingPathComponent(name), withIntermediateDirectories: false)
        } catch {
            alert = AlertMessage(title: "Could not create the folder", message: error.localizedDescription)
        }
    }

    /// Renames the file or folder in place; an editor tab of the file (or under the folder) closes first, asking
    /// about unsaved edits.
    func renameItem(_ path: String, project: String) {
        let current = (path as NSString).lastPathComponent
        guard let name = FileNamePrompt.ask("Rename", message: "New name for \(current):", placeholder: current, initial: current), name != current else { return }
        let destination = ((path as NSString).deletingLastPathComponent as NSString).appendingPathComponent(name)
        Task {
            guard await closeEditors(under: path) else { return }
            do {
                try FileManager.default.moveItem(atPath: path, toPath: destination)
            } catch {
                alert = AlertMessage(title: "Could not rename \(current)", message: error.localizedDescription)
            }
        }
    }

    /// Moves the file or folder to the Trash; its editor tabs close first, asking about unsaved edits.
    func trashItem(_ path: String, project: String) {
        Task {
            guard await closeEditors(under: path) else { return }
            do {
                try FileManager.default.trashItem(at: URL(filePath: path), resultingItemURL: nil)
            } catch {
                alert = AlertMessage(title: "Could not move \((path as NSString).lastPathComponent) to the Trash", message: error.localizedDescription)
            }
        }
    }
}

/// A one-line name prompt (`NSAlert` with a text field), run modally.
@MainActor
enum FileNamePrompt {
    static func ask(_ title: String, message: String, placeholder: String, initial: String = "") -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: title == "Rename" ? "Rename" : "Create")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = placeholder
        field.stringValue = initial
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !name.contains("/") else { return nil }
        return name
    }
}
