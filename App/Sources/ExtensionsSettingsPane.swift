import AppKit
import IDEExtensions
import SwiftUI
import UniformTypeIdentifiers

/// Settings › Extensions: VS Code extensions installed from `.vsix` files, and the editor theme for each appearance.
struct ExtensionsSettingsPane: View {
    private let extensions = EditorExtensions.shared
    @AppStorage(EditorExtensions.lightThemeKey, store: .lantern) private var lightTheme = ""
    @AppStorage(EditorExtensions.darkThemeKey, store: .lantern) private var darkTheme = ""
    @State private var isInstalling = false
    @State private var failure: String?

    var body: some View {
        Form {
            Section {
                themePicker("Light appearance", selection: $lightTheme, dark: false)
                themePicker("Dark appearance", selection: $darkTheme, dark: true)
            } header: {
                Text("Editor Theme")
            }
            Section {
                if extensions.catalog.extensions.isEmpty {
                    Text("No extensions installed.")
                        .foregroundStyle(.secondary)
                }
                ForEach(extensions.catalog.extensions) { installed in
                    ExtensionRow(installed: installed) { remove(installed) }
                }
                HStack {
                    Button("Install from VSIX…", action: chooseVSIX)
                        .disabled(isInstalling)
                    if isInstalling { ProgressView().controlSize(.small) }
                }
                if let failure {
                    Text(failure)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("Installed")
            } footer: {
                Text("Lantern uses an extension's color themes, snippets and new languages (file types, comment tokens, closing brackets). Extension code doesn't run, so commands, views and language features that need it aren't available. Download .vsix files from open-vsx.org or the extension's publisher.")
            }
        }
        .formStyle(.grouped)
        .onChange(of: lightTheme) { extensions.themeSelectionDidChange() }
        .onChange(of: darkTheme) { extensions.themeSelectionDidChange() }
        // A theme whose extension was removed: editors use Lantern's already, and the picker says so.
        .onChange(of: extensions.catalog.themes.map(\.id), initial: true) { _, ids in
            if !lightTheme.isEmpty, !ids.contains(lightTheme) { lightTheme = "" }
            if !darkTheme.isEmpty, !ids.contains(darkTheme) { darkTheme = "" }
        }
    }

    /// Lantern's theme, then the themes made for this appearance, then the others.
    private func themePicker(_ title: String, selection: Binding<String>, dark: Bool) -> some View {
        let themes = extensions.catalog.themes
        let matching = themes.filter { $0.isDark == dark }
        let others = themes.filter { $0.isDark != dark }
        return Picker(title, selection: selection) {
            Text("Lantern").tag("")
            if !matching.isEmpty { Divider() }
            ForEach(matching) { Text($0.label).tag($0.id) }
            if !others.isEmpty { Divider() }
            ForEach(others) { Text($0.label).tag($0.id) }
        }
    }

    private func chooseVSIX() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "vsix") ?? .zip]
        panel.allowsMultipleSelection = true
        panel.message = "Choose VS Code extension packages (.vsix) to install."
        panel.prompt = "Install"
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        failure = nil
        isInstalling = true
        Task {
            var problems: [String] = []
            for url in urls {
                do {
                    try await extensions.install(url)
                } catch {
                    problems.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            isInstalling = false
            failure = problems.isEmpty ? nil : problems.joined(separator: "\n")
        }
    }

    private func remove(_ installed: InstalledExtension) {
        failure = nil
        Task {
            do {
                try await extensions.uninstall(installed.id)
            } catch {
                failure = "\(installed.displayName): \(error.localizedDescription)"
            }
        }
    }
}

/// One installed extension: its name, version and publisher, and what Lantern takes from it.
private struct ExtensionRow: View {
    let installed: InstalledExtension
    let remove: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(installed.displayName)
                    Text(installed.version)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Text(contents)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .help(installed.summary ?? installed.id)
            Spacer()
            Button("Remove", action: remove)
        }
    }

    /// "Dracula Official · 2 themes", "Vue · 1 language · snippets".
    private var contents: String {
        var parts = [installed.publisher]
        let themes = installed.themes.count
        if themes > 0 { parts.append(themes == 1 ? "1 theme" : "\(themes) themes") }
        let languages = installed.languages.count
        if languages > 0 { parts.append(languages == 1 ? "1 language" : "\(languages) languages") }
        if !installed.snippets.isEmpty { parts.append("snippets") }
        return parts.joined(separator: " · ")
    }
}
