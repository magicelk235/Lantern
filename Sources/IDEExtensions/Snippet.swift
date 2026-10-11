import Foundation

/// A snippet from a VS Code snippet file.
public struct Snippet: Sendable, Hashable {
    /// The snippet's key in its file, which VS Code shows as its name.
    public let name: String
    /// What is typed for the snippet to be offered.
    public let prefixes: [String]
    /// The template `SnippetExpander` expands, its lines joined with `\n`.
    public let body: String
    /// The snippet's description.
    public let summary: String?

    public init(name: String, prefixes: [String], body: String, summary: String?) {
        self.name = name
        self.prefixes = prefixes
        self.body = body
        self.summary = summary
    }

    /// The order snippets are listed in: by name as Finder sorts names, then by prefixes and body for snippets of the
    /// same name.
    static func precedes(_ first: Snippet, _ second: Snippet) -> Bool {
        switch first.name.localizedStandardCompare(second.name) {
        case .orderedAscending: true
        case .orderedDescending: false
        case .orderedSame:
            (first.prefixes.joined(separator: "\n"), first.body)
                < (second.prefixes.joined(separator: "\n"), second.body)
        }
    }
}

/// Reads VS Code snippet files (`.json` or `.code-snippets`).
public enum SnippetFile {
    /// The snippets of the file at `url`, by name. Each is an entry `"name": { "prefix", "body", "description" }`, the
    /// prefix one string or several, the body a string or its lines, the description a string or its lines; an entry
    /// without a prefix or a body is left out. An entry that has no body but holds entries is a group of snippets, a
    /// layout of older files VS Code still reads.
    public static func load(_ url: URL) throws -> [Snippet] {
        guard let entries = try JSONC.object(from: Data(contentsOf: url)) as? [String: Any] else {
            throw ExtensionError.unreadable(url.lastPathComponent)
        }
        var snippets: [Snippet] = []
        for (name, value) in entries {
            guard let entry = value as? [String: Any] else { continue }
            if entry["body"] == nil {
                for (name, value) in entry {
                    if let entry = value as? [String: Any], let snippet = snippet(named: name, entry) {
                        snippets.append(snippet)
                    }
                }
            } else if let snippet = snippet(named: name, entry) {
                snippets.append(snippet)
            }
        }
        return snippets.sorted(by: Snippet.precedes)
    }

    private static func snippet(named name: String, _ entry: [String: Any]) -> Snippet? {
        let written: [String] = switch entry["prefix"] {
        case let prefix as String: [prefix]
        case let list as [Any]: list.compactMap { $0 as? String }
        default: []
        }
        let prefixes = written.filter { !$0.isEmpty }
        guard !prefixes.isEmpty, let body = lines(entry["body"]), !body.isEmpty else { return nil }
        let summary = lines(entry["description"]).flatMap { $0.isEmpty ? nil : $0 }
        return Snippet(name: name, prefixes: prefixes, body: body, summary: summary)
    }

    /// A string, or an array of lines joined with `\n`.
    private static func lines(_ value: Any?) -> String? {
        switch value {
        case let text as String: text
        case let list as [Any]: list.map { $0 as? String ?? "" }.joined(separator: "\n")
        default: nil
        }
    }
}
