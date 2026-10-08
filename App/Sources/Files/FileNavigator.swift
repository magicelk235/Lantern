import AppKit
import SwiftUI

/// What the activity bar can show in the sidebar. The last choice is kept in the defaults.
enum SidebarPane: String, CaseIterable {
    case files
    case changes
    case agents
    case projects

    static let defaultsKey = "sidebarPane"

    /// The rail's label under the symbol, its tooltip and its accessibility label.
    var title: String {
        switch self {
        case .files: "Files"
        case .changes: "Changes"
        case .agents: "Agents"
        case .projects: "Projects"
        }
    }

    var symbol: String {
        switch self {
        case .files: "folder"
        case .changes: "arrow.triangle.branch"
        case .agents: "person.2"
        case .projects: "square.stack.3d.up"
        }
    }

    /// As shown in tooltips; the shortcuts live in `LanternApp`'s View menu.
    var shortcut: String {
        switch self {
        case .files: "⇧⌘E"
        case .changes: "⌃⌘G"
        case .agents: "⌃⌘A"
        case .projects: "⇧⌘P"
        }
    }
}

/// The sidebar pane the activity bar picked: the project in focus (its title is the menu that switches projects and
/// adds one) with its files, its git changes or what omp runs in it, or the list of projects. The window of no
/// project shows nothing here but the list of projects: its detail area offers Add Project.
struct SidebarPaneView: View {
    @Bindable var app: AppState
    /// The window's project; empty for the window of no project.
    let project: String

    var body: some View {
        VStack(spacing: 0) {
            switch app.pane {
            case .files:
                if !project.isEmpty {
                    ProjectHeader(app: app, project: project)
                    Divider()
                    FilesOutline(app: app, project: project)
                        .id(project)
                }
            case .changes:
                if !project.isEmpty {
                    ProjectHeader(app: app, project: project)
                    Divider()
                    SourceControlPanel(app: app, repository: app.editors.repositories.repository(for: project))
                        .id(project)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            case .agents:
                if !project.isEmpty {
                    ProjectHeader(app: app, project: project)
                    Divider()
                    AgentsPane(app: app, project: project)
                        .id(project)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            case .projects:
                ProjectsPane(app: app, project: project)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Chrome.surface)
    }
}

/// The project's name as the switcher (the projects, Add Project, then what this project offers), and + with what
/// can be added to the project: a file or folder at its top level, a session or a terminal.
struct ProjectHeader: View {
    let app: AppState
    let project: String

    var body: some View {
        HStack(spacing: 6) {
            Menu {
                ForEach(app.projects, id: \.self) { candidate in
                    Toggle(AppState.projectName(candidate), isOn: Binding(
                        get: { candidate == project }, set: { if $0 { app.showProject(candidate) } }))
                }
                Divider()
                Button("Add Project…") { app.addProject() }
                Divider()
                ProjectMenu(app: app, project: project)
            } label: {
                HStack(spacing: 4) {
                    Text(AppState.projectName(project))
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    MenuChevron()
                }
            }
            .paneHeaderMenu()
            .help(project)
            Spacer(minLength: 4)
            Menu {
                Button("New File…") { app.newFile(in: project, project: project) }
                Button("New Folder…") { app.newFolder(in: project) }
                Divider()
                Button("New Session") { app.newSession(in: project) }
                    .disabled(!app.connection.isConnected)
                Button("New Terminal") { app.newTerminal(in: project) }
                    .disabled(!app.connection.isConnected)
            } label: {
                Image(systemName: "plus")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(.secondary)
            .help("New File, Folder, Session or Terminal in \(AppState.projectName(project))")
            .accessibilityLabel("New File, Folder, Session or Terminal")
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }
}

/// The pull-down chevron after a pane header's menu title.
struct MenuChevron: View {
    var body: some View {
        Image(systemName: "chevron.down")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.secondary)
            // The menu it marks says what it is.
            .accessibilityHidden(true)
    }
}

extension View {
    /// A pane header's title menu (the project switcher, the branch menu): its label is drawn as given, so a long title
    /// truncates in the middle (a borderless pop-up button cuts its own title at the end), and it is never wider than
    /// its title nor than the room the header leaves it.
    func paneHeaderMenu() -> some View {
        menuStyle(.button)
            .buttonStyle(.plain)
            .fixedSize(horizontal: false, vertical: true)
            .layoutPriority(1)
    }
}

/// The projects, this window's marked, each with what its sessions do at a glance (`ProjectBadge`); a click focuses a
/// project, bringing its window forward on Files.
private struct ProjectsPane: View {
    let app: AppState
    let project: String

    var body: some View {
        HStack {
            Text("Projects")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Button {
                app.addProject()
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Add a project folder (⌘O)")
            .accessibilityLabel("Add Project")
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 6)
        Divider()
        List(selection: Binding(get: { project.isEmpty ? nil : project }, set: { if let chosen = $0 { focus(chosen) } })) {
            ForEach(app.projects, id: \.self) { candidate in
                let activity = ProjectActivity(app: app, project: candidate)
                HStack(spacing: 8) {
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                    Text(AppState.projectName(candidate))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(candidate)
                    Spacer(minLength: 4)
                    ProjectBadge(activity: activity)
                }
                // One element for VoiceOver: the name, what its sessions do, and which they are.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(AppState.projectName(candidate))
                .accessibilityValue(activity.words ?? "")
                .accessibilityHint(activity.help ?? candidate)
                .tag(candidate)
                .listRowSeparator(.hidden)
                .contextMenu { ProjectMenu(app: app, project: candidate) }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 24)
        .overlay {
            // The window of no project: its detail area offers Add Project.
            if app.projects.isEmpty {
                Text("No Projects")
                    .foregroundStyle(.chromeSecondary)
            }
        }
    }

    /// A click on a project: its window comes forward showing its files. The pane is every window's, so this
    /// window's list goes too, and no row stays highlighted in it for a project it does not show.
    private func focus(_ chosen: String) {
        app.showPane(.files)
        app.showProject(chosen)
    }
}

/// A project's activity at a row's end (`ProjectActivityMark`): a red count of what waits on the user, else the lit
/// ember dot while one of its sessions works, else the blue dot while one finished a turn unseen. The tooltip names
/// those sessions and what each does.
private struct ProjectBadge: View {
    let activity: ProjectActivity

    var body: some View {
        if let mark = activity.mark {
            ProjectActivityMark(mark: mark)
                // A dot sits where the count's capsule would.
                .padding(.horizontal, mark == .working || mark == .finished ? 4 : 0)
                .help(activity.help ?? "")
        }
    }
}

/// The navigator's icon for a file, by extension; folders are folders.
enum FileSymbol {
    static func name(for fileName: String, isDirectory: Bool) -> String {
        if isDirectory { return "folder" }
        switch (fileName as NSString).pathExtension.lowercased() {
        case "swift": return "swift"
        case "md", "markdown", "txt", "rtf": return "doc.plaintext"
        case "json", "yml", "yaml", "toml", "plist", "xml": return "curlybraces"
        case "png", "jpg", "jpeg", "gif", "heic", "svg", "pdf", "icns": return "photo"
        case "sh", "zsh", "bash", "fish": return "terminal"
        default: return "doc.text"
        }
    }
}

/// What git says about the files of a project, for the Files pane, with the Changes list's letters: untracked files
/// (U) and staged additions (A) in green, changed ones (M) in yellow; a folder carries the color of what it holds
/// (changed wins).
@MainActor
struct GitMarks {
    enum Mark {
        case untracked, added, modified

        var color: NSColor {
            switch self {
            case .untracked, .added: Chrome.gitAddedColor
            case .modified: Chrome.gitModifiedColor
            }
        }

        var letter: String {
            switch self {
            case .untracked: "U"
            case .added: "A"
            case .modified: "M"
            }
        }

        /// The letter in words, for VoiceOver.
        var word: String {
            switch self {
            case .untracked: "untracked"
            case .added: "added"
            case .modified: "modified"
            }
        }

        var explanation: String {
            switch self {
            case .untracked: "Untracked: not in the repository yet"
            case .added: "Added to the repository, staged"
            case .modified: "Changed since the last commit"
            }
        }
    }

    private(set) var files: [String: Mark] = [:]
    private(set) var folders: [String: Mark] = [:]

    init(repository: GitRepository, root: String) {
        guard repository.isRepository else { return }
        for change in repository.changes {
            let mark: Mark = change.isUntracked ? .untracked : change.staged == "A" ? .added : .modified
            files[change.path] = mark
            var folder = (change.path as NSString).deletingLastPathComponent
            while folder.hasPrefix(root), folder != root {
                if folders[folder] != .modified { folders[folder] = mark }
                folder = (folder as NSString).deletingLastPathComponent
            }
        }
    }
}
