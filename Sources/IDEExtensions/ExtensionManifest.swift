import Foundation

/// A color theme an extension contributes (`contributes.themes` in its package.json).
public struct ThemeContribution: Sendable, Hashable, Identifiable {
    /// `<extension id>/<label>`.
    public let id: String
    /// The name the theme is listed by.
    public let label: String
    /// Whether the theme is for a dark appearance: VS Code's `uiTheme` `vs-dark` or `hc-black`.
    public let isDark: Bool
    /// The theme file, a VS Code JSON theme or a TextMate `.tmTheme`.
    public let path: URL

    public init(id: String, label: String, isDark: Bool, path: URL) {
        self.id = id
        self.label = label
        self.isDark = isDark
        self.path = path
    }
}

/// A snippet file an extension contributes for a language (`contributes.snippets`).
public struct SnippetContribution: Sendable, Hashable {
    /// The VS Code language identifier the snippets are for (`javascript`, `vue`).
    public let language: String
    public let path: URL

    public init(language: String, path: URL) {
        self.language = language
        self.path = path
    }
}

/// A language an extension declares or adds to (`contributes.languages`): which files are in it, what it is called and
/// its `language-configuration.json`.
public struct LanguageContribution: Sendable, Hashable {
    /// The VS Code language identifier.
    public let id: String
    /// What the language is called, the first being the name shown.
    public let aliases: [String]
    /// Endings of the names of the files in the language, lowercased and written as VS Code has them (`.vue`,
    /// `.d.ts`).
    public let extensions: [String]
    /// Whole names of files in the language (`Dockerfile`), in their case.
    public let filenames: [String]
    public let configuration: URL?

    public init(id: String, aliases: [String], extensions: [String], filenames: [String], configuration: URL?) {
        self.id = id
        self.aliases = aliases
        self.extensions = extensions
        self.filenames = filenames
        self.configuration = configuration
    }
}

/// An extension in the extensions folder, with what it contributes that the editor uses.
public struct InstalledExtension: Sendable, Hashable, Identifiable {
    /// `publisher.name` in lowercase, VS Code's identifier for the extension.
    public let id: String
    public let publisher: String
    public let name: String
    /// The name the extension is shown by: the manifest's `displayName`, else its `name`.
    public let displayName: String
    public let version: String
    /// The manifest's `description`.
    public let summary: String?
    /// The folder holding `package.json`, which the contributions' files are in.
    public let folder: URL
    public let themes: [ThemeContribution]
    public let snippets: [SnippetContribution]
    public let languages: [LanguageContribution]

    public init(
        id: String, publisher: String, name: String, displayName: String, version: String, summary: String?,
        folder: URL, themes: [ThemeContribution], snippets: [SnippetContribution], languages: [LanguageContribution]
    ) {
        self.id = id
        self.publisher = publisher
        self.name = name
        self.displayName = displayName
        self.version = version
        self.summary = summary
        self.folder = folder
        self.themes = themes
        self.snippets = snippets
        self.languages = languages
    }

    /// Whether the extension has a color theme, snippets or a language to offer; one made only of code, grammars or
    /// commands has nothing the editor can use.
    public var contributesAnything: Bool { !themes.isEmpty || !snippets.isEmpty || !languages.isEmpty }
}

/// Reads an extension's manifest, `package.json`.
public enum ExtensionManifest {
    /// The extension whose `package.json` is in `folder`.
    ///
    /// Strings written `%key%` are looked up in `package.nls.json` next to the manifest, as VS Code does for its
    /// default language, and the contributions' paths are taken relative to `folder`. A contribution whose fields are
    /// missing or wrong, or whose file is not there, is left out; a language with nothing but an identifier too.
    /// Throws `ExtensionError.notAnExtension` when there is no `package.json`, and `.unreadable` when it is not a
    /// manifest: not JSON, or without a `name` and `publisher` made of letters, digits, `-`, `_` and `.` (they name the
    /// extension's folder).
    public static func read(folder: URL) throws -> InstalledExtension {
        let manifestFile = folder.appending(path: "package.json", directoryHint: .notDirectory)
        guard FileManager.default.fileExists(atPath: manifestFile.path(percentEncoded: false)) else {
            throw ExtensionError.notAnExtension
        }
        guard let data = try? Data(contentsOf: manifestFile),
              let written = (try? JSONC.object(from: data)) as? [String: Any] else {
            throw ExtensionError.unreadable("package.json")
        }
        let messagesFile = folder.appending(path: "package.nls.json", directoryHint: .notDirectory)
        let messages = (try? Data(contentsOf: messagesFile)).flatMap { (try? JSONC.object(from: $0)) as? [String: Any] }
        let manifest = localized(written, messages: messages ?? [:]) as? [String: Any] ?? written
        let publisher = manifest["publisher"] as? String ?? "undefined_publisher"
        guard let name = manifest["name"] as? String, isIdentifierPart(name), isIdentifierPart(publisher) else {
            throw ExtensionError.unreadable("package.json")
        }
        let id = "\(publisher).\(name)".lowercased()
        let contributes = manifest["contributes"] as? [String: Any] ?? [:]
        return InstalledExtension(
            id: id,
            publisher: publisher,
            name: name,
            displayName: nonEmpty(manifest["displayName"]) ?? name,
            version: manifest["version"] as? String ?? "",
            summary: nonEmpty(manifest["description"]),
            folder: folder,
            themes: themes(entries(contributes["themes"]), extensionId: id, folder: folder),
            snippets: entries(contributes["snippets"]).compactMap { entry in
                guard let language = nonEmpty(entry["language"]), let path = file(entry["path"], in: folder) else {
                    return nil
                }
                return SnippetContribution(language: language, path: path)
            },
            languages: entries(contributes["languages"]).compactMap { entry in
                guard let id = nonEmpty(entry["id"]) else { return nil }
                let language = LanguageContribution(
                    id: id,
                    aliases: strings(entry["aliases"]),
                    extensions: strings(entry["extensions"]).map { $0.lowercased() },
                    filenames: strings(entry["filenames"]),
                    configuration: file(entry["configuration"], in: folder))
                let isEmpty = language.aliases.isEmpty && language.extensions.isEmpty && language.filenames.isEmpty
                    && language.configuration == nil
                return isEmpty ? nil : language
            })
    }

    /// The themes of `contributes.themes`; a theme without a label goes by its file's name, and a second one with the
    /// label of another is left out, as their identifiers would be the same.
    private static func themes(_ entries: [[String: Any]], extensionId: String, folder: URL) -> [ThemeContribution] {
        var themes: [ThemeContribution] = []
        for entry in entries {
            guard let path = file(entry["path"], in: folder) else { continue }
            let label = nonEmpty(entry["label"]) ?? path.deletingPathExtension().lastPathComponent
            let uiTheme = entry["uiTheme"] as? String
            let theme = ThemeContribution(
                id: "\(extensionId)/\(label)", label: label, isDark: uiTheme == "vs-dark" || uiTheme == "hc-black",
                path: path)
            if !themes.contains(where: { $0.id == theme.id }) { themes.append(theme) }
        }
        return themes
    }

    /// `value` with every string written `%key%` replaced by the message `messages` has for `key`, a string or an
    /// object with a `message`; a key without a message stays as written.
    private static func localized(_ value: Any, messages: [String: Any]) -> Any {
        switch value {
        case let text as String:
            guard text.count > 1, text.hasPrefix("%"), text.hasSuffix("%") else { return text }
            let key = String(text.dropFirst().dropLast())
            let message = messages[key] as? String ?? (messages[key] as? [String: Any])?["message"] as? String
            return message.flatMap { $0.isEmpty ? nil : $0 } ?? text
        case let array as [Any]:
            return array.map { localized($0, messages: messages) }
        case let object as [String: Any]:
            return object.mapValues { localized($0, messages: messages) }
        default:
            return value
        }
    }

    /// The file a contribution's `path` names relative to `folder`, when it is a file that is there.
    private static func file(_ value: Any?, in folder: URL) -> URL? {
        guard let path = value as? String, !path.isEmpty else { return nil }
        let url = folder.appending(path: path, directoryHint: .notDirectory).standardized
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory),
              !isDirectory.boolValue else { return nil }
        return url
    }

    /// Whether `text` can be a publisher or an extension name: ASCII letters, digits, `-`, `_` and `.`, starting with a
    /// letter or a digit, so the identifier names a folder inside the extensions folder.
    private static func isIdentifierPart(_ text: String) -> Bool {
        func isAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
            ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar) || ("0"..."9").contains(scalar)
        }
        guard let first = text.unicodeScalars.first, isAlphanumeric(first) else { return false }
        return text.unicodeScalars.allSatisfy { isAlphanumeric($0) || $0 == "-" || $0 == "_" || $0 == "." }
    }

    private static func entries(_ value: Any?) -> [[String: Any]] {
        (value as? [Any] ?? []).compactMap { $0 as? [String: Any] }
    }

    private static func strings(_ value: Any?) -> [String] {
        (value as? [Any] ?? []).compactMap { $0 as? String }.filter { !$0.isEmpty }
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        return text
    }
}
