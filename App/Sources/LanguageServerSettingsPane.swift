import IDELanguageModel
import SwiftUI

/// Settings › Languages: the language servers the editor starts. The built-in ones are listed as they are; the user's
/// own, each a command and the file extensions whose files it takes from the built-in server, are added, edited and
/// removed here. Edits go to the defaults (`LanguageServerSettings`) once typing pauses, and when the pane goes; the
/// open editors then join the servers their files take (`Editors`).
struct LanguageServerSettingsPane: View {
    @State private var drafts = LanguageServerSettings.customServers.map(ServerDraft.init)

    var body: some View {
        Form {
            Section("Built-in Servers") {
                ForEach(LanguageServerKind.allCases, id: \.self) { kind in
                    LabeledContent {
                        Text(kind.programNames.joined(separator: " or "))
                    } label: {
                        Text(kind.name)
                        Text(kind.fileExtensions.joined(separator: ", "))
                    }
                }
            }
            ForEach($drafts) { $draft in
                ServerSection(draft: $draft) { remove(draft.id) }
            }
            Section {
                Button("Add Server", systemImage: "plus") { drafts.append(ServerDraft(CustomLanguageServer())) }
            } footer: {
                Text("A server you add replaces the built-in one for its file extensions. Its command runs in your login shell’s environment, from the project folder.")
            }
        }
        .formStyle(.grouped)
        // Saved once typing pauses: each save moves the open editors of the files it concerns to another server.
        .task(id: servers) {
            guard (try? await Task.sleep(for: .seconds(1))) != nil else { return }
            save()
        }
        .onDisappear { save() }
    }

    /// The servers as edited.
    private var servers: [CustomLanguageServer] { drafts.map(\.server) }

    private func remove(_ id: ServerDraft.ID) {
        drafts.removeAll { $0.id == id }
    }

    private func save() {
        let servers = self.servers
        guard servers != LanguageServerSettings.customServers else { return }
        LanguageServerSettings.customServers = servers
    }
}

/// One of the user's servers as edited, its file extensions as typed: a comma or space just typed stays in the field.
private struct ServerDraft: Identifiable {
    let id: UUID
    var name: String
    var command: String
    var extensions: String
    var languageId: String

    init(_ server: CustomLanguageServer) {
        id = server.id
        name = server.name
        command = server.command
        extensions = server.fileExtensions.joined(separator: ", ")
        languageId = server.languageId
    }

    /// The server as saved: the extensions are what the commas and spaces typed separate, without their dots.
    var server: CustomLanguageServer {
        let fileExtensions = extensions.split { $0 == "," || $0.isWhitespace }
            .map { word in String(word.drop { $0 == "." }) }
            .filter { !$0.isEmpty }
        return CustomLanguageServer(
            id: id, name: name, command: command, fileExtensions: fileExtensions, languageId: languageId)
    }
}

/// A user's server: its fields, what keeps it from working under the field concerned, and its Remove button.
private struct ServerSection: View {
    @Binding var draft: ServerDraft
    let remove: () -> Void

    var body: some View {
        let server = draft.server
        let name = LanguageServerChoice.custom(server).name
        Section {
            TextField("Name", text: $draft.name)
            TextField("Command", text: $draft.command, prompt: Text("Program and arguments"))
            if server.arguments == nil {
                ServerProblem(text: "A quote in the command is not closed.")
            }
            TextField("File Extensions", text: $draft.extensions, prompt: Text("vue, svelte"))
            if server.fileExtensions.isEmpty {
                ServerProblem(text: "Add at least one file extension.")
            }
            TextField(
                "Language ID", text: $draft.languageId,
                prompt: Text(server.fileExtensions.first?.lowercased() ?? "First extension"))
        } header: {
            HStack {
                Text(name)
                Spacer()
                Button("Remove \(name)", systemImage: "minus.circle", action: remove)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Remove this server")
            }
        }
    }
}

/// What keeps a server from working, beside the system's warning triangle.
private struct ServerProblem: View {
    let text: String

    var body: some View {
        HStack(spacing: 5) {
            WarningMark()
            Text(text)
        }
    }
}
