import Foundation
import IDEExtensions
import IDEProtocol

/// The VS Code extensions installed in Lantern (`$APP_SUPPORT/extensions`) and what editors take from them: color
/// themes, snippets, and the languages they add (file types the editor has no grammar for, with their comment tokens,
/// closing pairs and name). Their code never runs. Installing or removing one posts `didChange`, as does picking
/// another theme, and every editor takes the change (`Editors`).
@MainActor @Observable
final class EditorExtensions {
    static let shared = EditorExtensions()

    /// The ids (`ThemeContribution.id`) of the themes editors use in the light and the dark appearance; empty or
    /// missing: Lantern's own.
    static let lightThemeKey = "editorThemeLight"
    static let darkThemeKey = "editorThemeDark"

    static let didChange = Notification.Name("LanternEditorExtensionsDidChange")

    private(set) var catalog: ExtensionCatalog

    @ObservationIgnored private let store: ExtensionStore
    /// Themes read so far by id; nil for one that could not be read.
    @ObservationIgnored private var themes: [String: ColorTheme?] = [:]

    private init() {
        store = ExtensionStore(folder: AppSupportPaths.standard.extensions)
        catalog = ExtensionCatalog(store.installed())
    }

    /// Installs (or updates) the extension packaged in `vsix`.
    @discardableResult
    func install(_ vsix: URL) async throws -> InstalledExtension {
        let store = store
        let installed = try await Task.detached(priority: .userInitiated) { try store.install(vsix: vsix) }.value
        await reload()
        return installed
    }

    func uninstall(_ id: String) async throws {
        let store = store
        try await Task.detached(priority: .userInitiated) { try store.uninstall(id: id) }.value
        await reload()
    }

    /// Another theme was picked in Settings.
    func themeSelectionDidChange() {
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    private func reload() async {
        let store = store
        catalog = await Task.detached(priority: .userInitiated) { ExtensionCatalog(store.installed()) }.value
        themes = [:]
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    // MARK: - Themes

    /// The theme picked for the dark or the light appearance; nil for Lantern's own, also when the one picked is no
    /// longer installed or cannot be read.
    func colorTheme(dark: Bool) -> ColorTheme? {
        guard let id = UserDefaults.lantern.string(forKey: dark ? Self.darkThemeKey : Self.lightThemeKey), !id.isEmpty
        else { return nil }
        if let theme = themes[id] { return theme }
        let theme = catalog.themes.first { $0.id == id }.flatMap { try? ColorTheme.load($0) }
        themes[id] = theme
        return theme
    }

    // MARK: - Languages

    /// The VS Code language id of the file at `path`, whose editor language is `treeSitterId`: the editor's own
    /// language when it has one, else one an extension adds for the file's name or extension.
    func languageId(path: String, treeSitterId: String) -> String? {
        ExtensionCatalog.languageId(treeSitterId: treeSitterId) ?? contributedLanguage(path: path, treeSitterId: treeSitterId)?.id
    }

    /// The language an extension adds for the file at `path`, when the editor has none for it (`treeSitterId` is
    /// plain text). A language the editor knows keeps its own settings.
    func contributedLanguage(path: String, treeSitterId: String) -> LanguageContribution? {
        guard ExtensionCatalog.languageId(treeSitterId: treeSitterId) == nil else { return nil }
        return catalog.language(forPath: path)
    }

    func snippets(path: String, treeSitterId: String) -> [Snippet] {
        guard let id = languageId(path: path, treeSitterId: treeSitterId) else { return [] }
        return catalog.snippets(forLanguage: id)
    }

    /// The comment tokens and pairs of the language an extension adds for the file (`contributedLanguage`).
    func configuration(path: String, treeSitterId: String) -> LanguageConfiguration? {
        contributedLanguage(path: path, treeSitterId: treeSitterId).flatMap { catalog.configuration(forLanguage: $0.id) }
    }
}
