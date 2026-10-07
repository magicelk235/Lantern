/// The name a language goes by in the status bar, the way Xcode and the language's own documentation write it.
public enum LanguageName {
    /// The name for the editor's language `id` (CodeEditLanguages' `TreeSitterLanguage` raw value: `typescript`,
    /// `cpp`, `objc`, …). An unknown one is shown capitalized.
    public static func display(id: String) -> String {
        switch id {
        case "agda": "Agda"
        case "bash": "Shell Script"
        case "c": "C"
        case "cpp": "C++"
        case "cSharp": "C#"
        case "css": "CSS"
        case "dart": "Dart"
        case "dockerfile": "Dockerfile"
        case "elixir": "Elixir"
        case "go": "Go"
        case "goMod": "Go Module"
        case "haskell": "Haskell"
        case "html": "HTML"
        case "java": "Java"
        case "javascript": "JavaScript"
        case "jsdoc": "JSDoc"
        case "json": "JSON"
        case "jsx": "JSX"
        case "julia": "Julia"
        case "kotlin": "Kotlin"
        case "lua": "Lua"
        case "markdown", "markdownInline": "Markdown"
        case "objc": "Objective-C"
        case "ocaml": "OCaml"
        case "ocamlInterface": "OCaml Interface"
        case "perl": "Perl"
        case "php": "PHP"
        case "python": "Python"
        case "regex": "Regular Expression"
        case "ruby": "Ruby"
        case "rust": "Rust"
        case "scala": "Scala"
        case "sql": "SQL"
        case "swift": "Swift"
        case "toml": "TOML"
        case "tsx": "TSX"
        case "typescript": "TypeScript"
        case "verilog": "Verilog"
        case "yaml": "YAML"
        case "zig": "Zig"
        case "plainText", "": "Plain Text"
        default: id.prefix(1).uppercased() + id.dropFirst()
        }
    }
}
