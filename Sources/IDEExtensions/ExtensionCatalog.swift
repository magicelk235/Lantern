import Foundation

/// The installed extensions' contributions as the editor looks them up: the themes, the language of a file, and each
/// language's snippets, configuration and name.
public struct ExtensionCatalog: Sendable {
    /// The extensions, an earlier one winning where two contribute the same thing.
    public let extensions: [InstalledExtension]
    private let snippetsByLanguage: [String: [Snippet]]
    private let configurations: [String: LanguageConfiguration]

    /// Reads the snippet files and language configurations of `extensions` now, passing over those that cannot be
    /// read. Reads the disk: call it off the main thread.
    public init(_ extensions: [InstalledExtension]) {
        self.extensions = extensions
        var snippets: [String: [Snippet]] = [:]
        var configurations: [String: LanguageConfiguration] = [:]
        for installed in extensions {
            for contribution in installed.snippets {
                guard let file = try? SnippetFile.load(contribution.path) else { continue }
                snippets[contribution.language, default: []] += file
            }
            for language in installed.languages where configurations[language.id] == nil {
                guard let url = language.configuration, let configuration = try? LanguageConfiguration.load(url) else {
                    continue
                }
                configurations[language.id] = configuration
            }
        }
        snippetsByLanguage = snippets.mapValues { $0.sorted(by: Snippet.precedes) }
        self.configurations = configurations
    }

    /// The themes of every extension.
    public var themes: [ThemeContribution] { extensions.flatMap(\.themes) }

    /// The language of the file at `path`: the first that lists the file's name exactly, else the one that lists the
    /// longest ending of the name in any case (`.d.ts` before `.ts`), the first of those listing the same ending.
    public func language(forPath path: String) -> LanguageContribution? {
        let name = (path as NSString).lastPathComponent
        let languages = extensions.flatMap(\.languages)
        if let named = languages.first(where: { $0.filenames.contains(name) }) { return named }
        let lowercased = name.lowercased()
        var match: (language: LanguageContribution, length: Int)?
        for language in languages {
            for ending in language.extensions where ending.count > match?.length ?? 0 && lowercased.hasSuffix(ending) {
                match = (language, ending.count)
            }
        }
        return match?.language
    }

    /// The snippets of every extension for the language `id`, by name.
    public func snippets(forLanguage id: String) -> [Snippet] {
        snippetsByLanguage[id] ?? []
    }

    /// The configuration of the language `id`: the first that could be read.
    public func configuration(forLanguage id: String) -> LanguageConfiguration? {
        configurations[id]
    }

    /// The name of the language `id`: the first alias the first extension that gives it any has for it.
    public func displayName(forLanguage id: String) -> String? {
        extensions.lazy.flatMap(\.languages).first { $0.id == id && !$0.aliases.isEmpty }?.aliases.first
    }

    /// The VS Code identifier of the language the editor's highlighting calls `treeSitterId` (CodeEditLanguages'
    /// `TreeSitterLanguage` raw value), so it finds the snippets and configuration extensions give that language; nil
    /// for plain text and the languages VS Code has no identifier of its own for.
    public static func languageId(treeSitterId: String) -> String? {
        languageIds[treeSitterId]
    }

    private static let languageIds: [String: String] = [
        "bash": "shellscript", "c": "c", "cpp": "cpp", "cSharp": "csharp", "css": "css", "dart": "dart",
        "dockerfile": "dockerfile", "elixir": "elixir", "go": "go", "goMod": "go.mod", "haskell": "haskell",
        "html": "html", "java": "java", "javascript": "javascript", "jsx": "javascriptreact", "json": "json",
        "julia": "julia", "kotlin": "kotlin", "lua": "lua", "markdown": "markdown", "objc": "objective-c",
        "ocaml": "ocaml", "perl": "perl", "php": "php", "python": "python", "ruby": "ruby", "rust": "rust",
        "scala": "scala", "sql": "sql", "swift": "swift", "toml": "toml", "tsx": "typescriptreact",
        "typescript": "typescript", "verilog": "verilog", "yaml": "yaml", "zig": "zig",
    ]
}
