import Foundation

/// A language server the user added (Settings › Languages): the command that starts it and the extensions of the files
/// it takes, whose built-in server it replaces. The app keeps the list in its defaults (`encode`, `load`); the first
/// server in it that takes an extension gets that extension's files.
public struct CustomLanguageServer: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    /// The program and its arguments, separated by spaces and quoted as in a shell, though nothing is expanded but
    /// a `~` that starts the program's path: '…' keeps what is in it as it is, "…" too but for a backslash before `"`,
    /// `\`, `$` or a backquote, which stands for that character, and a backslash outside quotes keeps the character
    /// after it.
    public var command: String
    /// The extensions of the files it takes, without the dot, in any case.
    public var fileExtensions: [String]
    /// The `languageId` its files open with (`textDocument/didOpen`); empty for the first file extension.
    public var languageId: String

    public init(
        id: UUID = UUID(), name: String = "", command: String = "", fileExtensions: [String] = [],
        languageId: String = ""
    ) {
        self.id = id
        self.name = name
        self.command = command
        self.fileExtensions = fileExtensions
        self.languageId = languageId
    }

    /// The command's words, the program and then its arguments, with their quotes and backslashes taken out
    /// (`command`); empty for a blank command, nil when a quote is left open.
    public var arguments: [String]? {
        var words: [String] = []
        var word = ""
        // Whether a word has begun: quotes begin one that may stay empty.
        var inWord = false
        var characters = command.makeIterator()
        while let character = characters.next() {
            switch character {
            case "'":
                inWord = true
                while true {
                    guard let next = characters.next() else { return nil }
                    if next == "'" { break }
                    word.append(next)
                }
            case "\"":
                inWord = true
                while true {
                    guard let next = characters.next() else { return nil }
                    if next == "\"" { break }
                    guard next == "\\" else {
                        word.append(next)
                        continue
                    }
                    guard let escaped = characters.next() else { return nil }
                    if !"\"\\$`".contains(escaped) { word.append(next) }
                    word.append(escaped)
                }
            case "\\":
                inWord = true
                // A backslash at the very end stands for itself.
                word.append(characters.next() ?? "\\")
            case _ where character.isWhitespace:
                if inWord { words.append(word) }
                word = ""
                inWord = false
            default:
                inWord = true
                word.append(character)
            }
        }
        if inWord { words.append(word) }
        return words
    }

    /// The command to start, its program found: a path that starts with `~` is in `homeDirectory`, an absolute path is
    /// the program when `isExecutable` takes it, and a name alone is looked for in the absolute folders of `searchPath`
    /// (a `PATH` value), in order. Nil for a program not found that way (a relative path never is), and for a command
    /// with no program (`arguments`).
    public func resolve(
        searchPath: String, homeDirectory: String, isExecutable: (String) -> Bool
    ) -> LanguageServerCommand? {
        guard let words = arguments, var program = words.first, !program.isEmpty else { return nil }
        if program == "~" || program.hasPrefix("~/") {
            program = (homeDirectory as NSString).appendingPathComponent(String(program.dropFirst(2)))
        }
        let executable: String? =
            if program.hasPrefix("/") {
                isExecutable(program) ? program : nil
            } else if !program.contains("/") {
                LanguageServerLocator.find(program, in: searchPath, accepts: isExecutable)
            } else {
                nil
            }
        return executable.map { LanguageServerCommand(executable: $0, arguments: Array(words.dropFirst())) }
    }

    /// Whether it takes the files whose extension is `pathExtension` (lowercase).
    func takes(_ pathExtension: String) -> Bool {
        !pathExtension.isEmpty && fileExtensions.contains { $0.lowercased() == pathExtension }
    }

    /// The `languageId` its files open with: the one given, or else the first file extension.
    var documentLanguageId: String {
        let given = languageId.trimmingCharacters(in: .whitespaces)
        return given.isEmpty ? (fileExtensions.first?.lowercased() ?? "") : given
    }

    /// The servers `encode` made `data` of; none without data, and for data that is not such a list.
    public static func load(from data: Data?) -> [CustomLanguageServer] {
        data.flatMap { try? JSONDecoder().decode([CustomLanguageServer].self, from: $0) } ?? []
    }

    /// `servers` as the defaults keep them, JSON.
    public static func encode(_ servers: [CustomLanguageServer]) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(servers)) ?? Data()
    }
}
