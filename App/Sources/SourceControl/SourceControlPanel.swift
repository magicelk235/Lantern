import AppKit
import SwiftUI

/// The Changes side of the trailing panel: the branch and its menu, the commit message, and the project's changes in
/// two lists, Staged and Changes (untracked files among the latter with a `U`). A click on a change shows its diff
/// against HEAD; Return or a double-click opens the file in the project's strip; hovering a row shows Stage (+) or
/// Unstage (−).
struct SourceControlPanel: View {
    let app: AppState
    @Bindable var repository: GitRepository
    @State private var selection: Set<ChangeSelection> = []
    @FocusState private var messageFocused: Bool
    /// A click's diff, held for the double-click interval: a double-click opens the file instead.
    @State private var pendingCompare: Task<Void, Never>?

    var body: some View {
        Group {
            if !repository.hasLoaded {
                Color.clear
            } else if !repository.isGitAvailable {
                ContentUnavailableView {
                    Text("Git Is Not Installed")
                } description: {
                    Text("Source control needs the git of the Xcode Command Line Tools or of Homebrew.")
                }
            } else if !repository.isRepository {
                ContentUnavailableView {
                    Text("Not a Git Repository")
                } description: {
                    Text("Initialize one to track the changes in “\(AppState.projectName(repository.workspace))”.")
                } actions: {
                    Button("Initialize Repository") { repository.initialize() }
                        .controlSize(.small)
                        .disabled(repository.isBusy)
                }
            } else {
                changes
            }
        }
        .task(id: repository.workspace) {
            app.editors.watch(repository.workspace)
            repository.refresh()
        }
        .sheet(item: $repository.comparison) { comparison in
            ChangeDiffSheet(app: app, repository: repository, comparison: comparison)
        }
        .sheet(isPresented: $repository.isNamingBranch) {
            NewBranchSheet(repository: repository)
        }
    }

    private var changes: some View {
        VStack(spacing: 0) {
            branchRow
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            commitArea
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            Divider()
            if let failure = repository.lastError {
                NoticeBar(systemImage: "exclamationmark.triangle", tint: .red, title: failure.title, message: failure.message) {
                    Button("Dismiss") { repository.lastError = nil }
                }
                .help(failure.message)
            }
            if repository.changes.isEmpty {
                ContentUnavailableView {
                    Text("No Changes")
                } description: {
                    Text("The working tree matches the last commit.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list
            }
        }
    }

    /// The branch with its menu (switch, New Branch…, Fetch, Pull, Push); trailing, what is ahead or behind the
    /// upstream, or a spinner while an action runs.
    private var branchRow: some View {
        HStack(spacing: 6) {
            Menu {
                Section("Branches") {
                    ForEach(repository.branches, id: \.self) { name in
                        Toggle(name, isOn: Binding(get: { name == repository.branch }, set: { if $0 { repository.switchBranch(name) } }))
                    }
                }
                Button("New Branch…") { repository.beginNamingBranch() }
                Divider()
                Button("Fetch") { repository.fetch() }
                Button("Pull") { repository.pull() }
                    .disabled(repository.branch == nil)
                Button("Push") { repository.push() }
                    .disabled(repository.branch == nil)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.triangle.branch")
                        .foregroundStyle(.secondary)
                    Text(headTitle)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    MenuChevron()
                }
            }
            .paneHeaderMenu()
            .disabled(repository.isBusy)
            .help(repository.branch.map { "Branch \($0)" } ?? "Detached HEAD")
            Spacer(minLength: 4)
            if repository.isBusy {
                ProgressView()
                    .controlSize(.small)
            } else if repository.ahead > 0 || repository.behind > 0 {
                HStack(spacing: 6) {
                    if repository.ahead > 0 {
                        Label("\(repository.ahead)", systemImage: "arrow.up")
                    }
                    if repository.behind > 0 {
                        Label("\(repository.behind)", systemImage: "arrow.down")
                    }
                }
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .help("\(repository.ahead) to push, \(repository.behind) to pull")
            }
        }
    }

    private var headTitle: String {
        if let branch = repository.branch { return branch }
        return repository.headCommit.map { "detached at \($0)" } ?? "No commits"
    }

    /// The message and Commit (⌘↩); the menu next to it stages everything first.
    private var commitArea: some View {
        VStack(spacing: 6) {
            TextField("Commit message", text: $repository.commitMessage, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...6)
                .font(.system(size: 12))
                .focused($messageFocused)
                .onChange(of: app.editors.repositories.commitFocusPending, initial: true) { _, pending in
                    guard pending else { return }
                    app.editors.repositories.commitFocusPending = false
                    // The field takes focus once it is in the window, a turn after it appears.
                    Task { messageFocused = true }
                }
            HStack(spacing: 6) {
                Spacer()
                Button("Commit") { repository.commit() }
                    .buttonStyle(ProminentWhileEnabled())
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!repository.canCommit)
                    .help("Commit what is staged (⌘↩)")
                Menu {
                    Button("Stage All and Commit") { repository.commit(stagingAll: true) }
                        .disabled(!repository.canStageAllAndCommit)
                } label: {
                    Image(systemName: "chevron.down")
                }
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(repository.isBusy)
            }
            .controlSize(.small)
        }
    }

    private var list: some View {
        let staged = repository.stagedChanges
        let unstaged = repository.unstagedChanges
        return List(selection: $selection) {
            if !staged.isEmpty {
                Section {
                    ForEach(staged) { change in
                        ChangeRow(change: change, letter: change.staged ?? ".", staged: true, folder: folder(of: change)) {
                            pendingCompare?.cancel()
                            repository.unstage([change])
                        }
                        .simultaneousGesture(TapGesture().onEnded { clicked(change) })
                        .tag(ChangeSelection(path: change.path, staged: true))
                    }
                } header: {
                    sectionHeader("Staged", count: staged.count)
                }
            }
            if !unstaged.isEmpty {
                Section {
                    ForEach(unstaged) { change in
                        ChangeRow(change: change, letter: change.unstaged ?? ".", staged: false, folder: folder(of: change)) {
                            pendingCompare?.cancel()
                            repository.stage([change])
                        }
                        .simultaneousGesture(TapGesture().onEnded { clicked(change) })
                        .tag(ChangeSelection(path: change.path, staged: false))
                    }
                } header: {
                    sectionHeader("Changes", count: unstaged.count)
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 22)
        .contextMenu(forSelectionType: ChangeSelection.self) { items in
            contextMenu(for: items)
        } primaryAction: { items in
            pendingCompare?.cancel()
            open(items)
        }
    }

    /// A plain click shows the change against HEAD once no second click follows (a ⌘- or ⇧-click only selects).
    private func clicked(_ change: GitRepository.Change) {
        pendingCompare?.cancel()
        pendingCompare = nil
        guard let event = NSApp.currentEvent, event.clickCount == 1,
              event.modifierFlags.intersection([.command, .shift]).isEmpty
        else { return }
        pendingCompare = Task {
            try? await Task.sleep(for: .seconds(NSEvent.doubleClickInterval))
            guard !Task.isCancelled else { return }
            repository.compare(change)
        }
    }

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text("\(count)")
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    /// The change's folder under the project, for the row; empty at the top level.
    private func folder(of change: GitRepository.Change) -> String {
        let prefix = repository.workspace + "/"
        let shown = change.path.hasPrefix(prefix) ? String(change.path.dropFirst(prefix.count)) : (change.path as NSString).abbreviatingWithTildeInPath
        return (shown as NSString).deletingLastPathComponent
    }

    @ViewBuilder
    private func contextMenu(for items: Set<ChangeSelection>) -> some View {
        let changes = changes(for: items)
        if !changes.isEmpty {
            Button("Open") { open(items) }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting(changes.map { URL(filePath: $0.path) })
            }
            if changes.count == 1, let change = changes.first {
                Button("Compare with HEAD…") { repository.compare(change) }
            }
            Divider()
            if items.contains(where: { !$0.staged }) {
                Button("Stage") { repository.stage(changes.filter { $0.unstaged != nil }) }
                    .disabled(repository.isBusy)
            }
            if items.contains(where: \.staged) {
                Button("Unstage") { repository.unstage(changes.filter { $0.staged != nil }) }
                    .disabled(repository.isBusy)
            }
            if changes.count == 1, let change = changes.first, items.contains(where: { !$0.staged }), change.unstaged != nil {
                Button("Discard Changes…") { confirmDiscard(change) }
                    .disabled(repository.isBusy)
            }
        }
    }

    private func changes(for items: Set<ChangeSelection>) -> [GitRepository.Change] {
        let paths = Set(items.map(\.path))
        return repository.changes.filter { paths.contains($0.path) }
    }

    /// Return or a double-click: opens the files that still exist in the project's strip.
    private func open(_ items: Set<ChangeSelection>) {
        for change in changes(for: items) where FileManager.default.fileExists(atPath: change.path) {
            app.openEditor(change.path, in: repository.workspace)
        }
    }

    /// Discard asks first, in a sheet on the window: the work tree copy cannot be brought back.
    private func confirmDiscard(_ change: GitRepository.Change) {
        let confirmation = NSAlert()
        if change.isUntracked {
            confirmation.messageText = "Move “\(change.name)” to the Trash?"
            confirmation.informativeText = "Git does not track the file, so discarding it moves it to the Trash."
            confirmation.addButton(withTitle: "Move to Trash")
        } else {
            confirmation.messageText = "Discard the changes to “\(change.name)”?"
            confirmation.informativeText = "The file goes back to its last staged version. This cannot be undone."
            confirmation.addButton(withTitle: "Discard")
        }
        confirmation.buttons[0].hasDestructiveAction = true
        confirmation.addButton(withTitle: "Cancel")
        Task {
            let response = if let window = NSApp.keyWindow ?? NSApp.mainWindow {
                await confirmation.beginSheetModal(for: window)
            } else {
                confirmation.runModal()
            }
            if response == .alertFirstButtonReturn { repository.discard(change) }
        }
    }
}

/// The prominent push button while it can act, the plain bordered one, which the system greys out, while it cannot:
/// a disabled `.borderedProminent` button keeps its accent fill and reads as enabled.
private struct ProminentWhileEnabled: PrimitiveButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    @ViewBuilder
    func makeBody(configuration: Configuration) -> some View {
        if isEnabled {
            Button(configuration).buttonStyle(.borderedProminent)
        } else {
            Button(configuration).buttonStyle(.bordered)
        }
    }
}

/// A row of the Changes panel: the same path may be listed under Staged and under Changes.
private struct ChangeSelection: Hashable {
    let path: String
    let staged: Bool
}

/// One changed file: name, folder, and trailing its status letter; Stage or Unstage shows on hover.
private struct ChangeRow: View {
    let change: GitRepository.Change
    /// `M`, `A`, `D`, `R`, `C`, `T`, `U` (untracked) or `!` (conflicted).
    let letter: Character
    /// Listed under Staged: the hover button unstages.
    let staged: Bool
    let folder: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: FileSymbol.name(for: change.name, isDirectory: false))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(change.name)
                .lineLimit(1)
                .truncationMode(.middle)
            if !folder.isEmpty {
                Text(folder)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 4)
            Button(action: action) {
                Image(systemName: staged ? "minus" : "plus")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(hovering ? 1 : 0)
            .help(staged ? "Unstage" : "Stage")
            .accessibilityLabel(staged ? "Unstage \(change.name)" : "Stage \(change.name)")
            Text(String(letter))
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(change.isConflicted ? Color.red : Color.secondary)
                .frame(width: 12, alignment: .trailing)
                .help(statusWord)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(change.path)
        .accessibilityLabel("\(change.name), \(statusWord)")
    }

    private var statusWord: String {
        switch letter {
        case "M": "Modified"
        case "A": "Added"
        case "D": "Deleted"
        case "R": "Renamed" + (change.originalPath.map { " from \($0)" } ?? "")
        case "C": "Copied" + (change.originalPath.map { " from \($0)" } ?? "")
        case "T": "Type changed"
        case "U": "Untracked"
        case "!": "Conflicted"
        default: String(letter)
        }
    }
}

/// HEAD's version of a changed file against the work tree, as a unified line diff.
private struct ChangeDiffSheet: View {
    let app: AppState
    let repository: GitRepository
    let comparison: GitRepository.Comparison
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        DiffSheet(
            title: "“\(comparison.change.name)” in HEAD and in the working tree", removedLegend: "− only in HEAD",
            insertedLegend: "+ only in the working tree", hunks: comparison.hunks
        ) {
            Button("Open in Editor") {
                app.openEditor(comparison.change.path, in: repository.workspace)
                dismiss()
            }
            .disabled(!FileManager.default.fileExists(atPath: comparison.change.path))
            Spacer()
            Button("Close") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
    }
}

/// New Branch…: a name, made from HEAD and checked out. A name git refuses keeps the sheet up with git's reason.
private struct NewBranchSheet: View {
    let repository: GitRepository
    @State private var name = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Branch")
                .font(.headline)
            TextField("Branch name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(create)
            Text("Made from \(repository.branch ?? "the current commit") and checked out.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let failure = repository.lastError {
                Text(failure.message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create", action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid || repository.isBusy)
            }
        }
        .padding(16)
        .frame(width: 340)
    }

    private var isValid: Bool {
        !name.isEmpty && !name.contains(where: \.isWhitespace)
    }

    private func create() {
        guard isValid else { return }
        repository.createBranch(name)
    }
}

extension AppState {
    /// Source Control › Show Changes and Commit…: the trailing panel opens on its Changes side for the project on
    /// screen; Commit… also puts the caret in the commit message.
    func showChanges(focusingCommitMessage: Bool = false) {
        showPane(.changes)
        if focusingCommitMessage { editors.repositories.commitFocusPending = true }
    }
}

/// The Source Control menu, for the project on screen: Commit… (⌥⌘C), Stage All, Fetch, Pull (⌥⌘X), Push, Switch
/// Branch, New Branch…, and Show Changes (⌃⌘G). All but Show Changes need the project to be a repository.
struct SourceControlCommands: Commands {
    let app: AppState

    var body: some Commands {
        CommandMenu("Source Control") {
            let repository = app.currentProject.map { app.editors.repositories.repository(for: $0) }
            let isRepository = repository?.isRepository == true
            let ready = isRepository && repository?.isBusy == false
            Button("Commit…") { app.showChanges(focusingCommitMessage: true) }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled(!isRepository)
            Button("Stage All") { repository?.stageAll() }
                .disabled(!ready || repository?.changes.isEmpty != false)
            Divider()
            Button("Fetch") { repository?.fetch() }
                .disabled(!ready)
            Button("Pull") { repository?.pull() }
                .keyboardShortcut("x", modifiers: [.command, .option])
                .disabled(!ready || repository?.branch == nil)
            Button("Push") { repository?.push() }
                .disabled(!ready || repository?.branch == nil)
            Divider()
            Menu("Switch Branch") {
                if let repository {
                    ForEach(repository.branches, id: \.self) { name in
                        Toggle(name, isOn: Binding(get: { name == repository.branch }, set: { if $0 { repository.switchBranch(name) } }))
                    }
                }
            }
            .disabled(!ready || repository?.branches.isEmpty != false)
            Button("New Branch…") {
                app.showChanges()
                repository?.beginNamingBranch()
            }
            .disabled(!ready)
            Divider()
            Button("Show Changes") { app.showChanges() }
                .keyboardShortcut("g", modifiers: [.command, .control])
        }
    }
}
