import Foundation
import LanguageServerProtocol

// MARK: - Hover

/// A piece of what a server shows on hover (`textDocument/hover`), as the editor's popover lays it out.
public enum HoverBlock: Sendable, Hashable {
    /// Markdown text (inline formatting only; the popover does not lay out lists or headings).
    case markdown(String)
    /// Text shown as is.
    case plain(String)
    /// Code, in the editor's font.
    case code(String)
    /// A horizontal rule (`---`), which servers put between a declaration and its documentation.
    case rule

    /// The hover's contents split into blocks: fenced code blocks and rules out of markdown, the language/value pairs
    /// of the older `MarkedString` form as code. Whitespace-only blocks are dropped.
    public static func blocks(of hover: Hover) -> [HoverBlock] {
        switch hover.contents {
        case .optionA(let marked):
            blocks(of: marked)
        case .optionB(let marked):
            marked.flatMap(blocks(of:))
        case .optionC(let content):
            content.kind == .markdown ? markdownBlocks(content.value) : plain(content.value)
        }
    }

    private static func blocks(of marked: MarkedString) -> [HoverBlock] {
        switch marked {
        case .optionA(let markdown): markdownBlocks(markdown)
        case .optionB(let pair): code(pair.value)
        }
    }

    private static func plain(_ text: String) -> [HoverBlock] {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? [] : [.plain(text)]
    }

    private static func code(_ text: String) -> [HoverBlock] {
        let text = text.trimmingCharacters(in: .newlines)
        return text.trimmingCharacters(in: .whitespaces).isEmpty ? [] : [.code(text)]
    }

    /// Splits markdown at fenced code blocks (``` or ~~~) and at rule lines.
    private static func markdownBlocks(_ markdown: String) -> [HoverBlock] {
        var blocks: [HoverBlock] = []
        var text: [Substring] = []
        var fence: Substring?
        var codeLines: [Substring] = []

        func flushText() {
            let joined = text.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { blocks.append(.markdown(joined)) }
            text.removeAll()
        }

        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.drop { $0 == " " }
            if let open = fence {
                if trimmed.hasPrefix(open), trimmed.drop(while: { $0 == open.first }).allSatisfy(\.isWhitespace) {
                    blocks += code(codeLines.joined(separator: "\n"))
                    codeLines.removeAll()
                    fence = nil
                } else {
                    codeLines.append(line)
                }
            } else if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushText()
                fence = trimmed.prefix { $0 == trimmed.first }
            } else if isRule(trimmed) {
                flushText()
                blocks.append(.rule)
            } else {
                text.append(line)
            }
        }
        if fence != nil { blocks += code(codeLines.joined(separator: "\n")) }
        flushText()
        return blocks
    }

    /// Three or more of the same `-`, `*` or `_`, nothing else but spaces.
    private static func isRule(_ line: Substring) -> Bool {
        let marks = line.filter { !$0.isWhitespace }
        guard marks.count >= 3, let mark = marks.first, "-*_".contains(mark) else { return false }
        return marks.allSatisfy { $0 == mark }
    }
}

// MARK: - Definitions

/// Where a symbol is defined (`textDocument/definition`): a file and the range to select in it.
public struct DefinitionTarget: Sendable, Hashable {
    public let path: String
    /// In the target file's positions; a link's selection range (the name), not its whole extent.
    public let range: LSPRange

    public init(path: String, range: LSPRange) {
        self.path = path
        self.range = range
    }

    /// The response's targets in files, in the server's order without repeats; other URI schemes are dropped.
    public static func targets(from response: DefinitionResponse) -> [DefinitionTarget] {
        let all: [(DocumentUri, LSPRange)] = switch response {
        case .optionA(let location): [(location.uri, location.range)]
        case .optionB(let locations): locations.map { ($0.uri, $0.range) }
        case .optionC(let links): links.map { ($0.targetUri, $0.targetSelectionRange) }
        case nil: []
        }
        var seen = Set<DefinitionTarget>()
        return all.compactMap { uri, range in
            guard let path = DocumentURI.path(of: uri) else { return nil }
            let target = DefinitionTarget(path: path, range: range)
            return seen.insert(target).inserted ? target : nil
        }
    }

    /// The target's range in `text`, the text of its file; an empty one (some servers point at a name's start) is the
    /// name there.
    public func range(in text: NSString) -> NSRange {
        let range = LineTable(text).range(of: range, in: text)
        guard range.length == 0 else { return range }
        var start = range.location
        var end = range.location
        while start > 0, Self.isNameCharacter(text.character(at: start - 1)) { start -= 1 }
        while end < text.length, Self.isNameCharacter(text.character(at: end)) { end += 1 }
        return NSRange(location: start, length: end - start)
    }

    private static func isNameCharacter(_ unit: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else { return false }
        return scalar == "_" || CharacterSet.alphanumerics.contains(scalar)
    }

    /// The line it starts on, counted from 1.
    public var lineNumber: Int { range.start.line + 1 }
}

// MARK: - Completions

/// One completion a server offers (`textDocument/completion`), ready for the editor's suggestion list: its text is
/// plain (snippet placeholders filled with their defaults), and its edit range is in the positions of the text it was
/// asked for.
public struct CompletionCandidate: Sendable, Hashable {
    /// What the item is, for its icon.
    public enum Category: Sendable, Hashable {
        case function, method, constructor, variable, property, field, constant, type, enumMember, module, keyword, snippet,
            other
    }

    public let label: String
    public let category: Category
    public let detail: String?
    /// The documentation's summary: its first paragraph, at most `summaryLimit` characters (the whole of it is the
    /// hover's). The suggestion window's preview grows with its text and has no limit of its own.
    public let documentation: String?
    /// What replaces the typed prefix.
    public let insertText: String
    /// The range the server says the text replaces (its `textEdit`'s, the insert range of an insert/replace edit);
    /// nil: the word before the caret.
    public let replacing: LSPRange?
    /// What typing narrows the list by.
    public let filterText: String
    public let sortText: String
    public let deprecated: Bool
    /// Other edits that come with it (an import), in the same positions.
    public let additionalEdits: [TextEdit]

    public init(
        label: String, category: Category, insertText: String, detail: String? = nil, documentation: String? = nil,
        replacing: LSPRange? = nil, filterText: String? = nil, sortText: String? = nil, deprecated: Bool = false,
        additionalEdits: [TextEdit] = []
    ) {
        self.label = label
        self.category = category
        self.insertText = insertText
        self.detail = detail
        self.documentation = documentation.flatMap(Self.summary)
        self.replacing = replacing
        self.filterText = filterText ?? label
        self.sortText = sortText ?? label
        self.deprecated = deprecated
        self.additionalEdits = additionalEdits
    }

    static let summaryLimit = 300

    /// `documentation`'s first paragraph (up to the first blank line, a fenced code block or a rule), its lines joined,
    /// cut at a word to `summaryLimit` characters with "…"; nil when nothing is left.
    static func summary(_ documentation: String) -> String? {
        var lines: [Substring] = []
        for line in documentation.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { if lines.isEmpty { continue } else { break } }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("---") || trimmed.hasPrefix("***") { break }
            lines.append(Substring(trimmed))
        }
        let paragraph = lines.joined(separator: " ")
        guard !paragraph.isEmpty else { return nil }
        guard paragraph.count > summaryLimit else { return paragraph }
        let cut = paragraph.prefix(summaryLimit)
        let word = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
        return word.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)) + "…"
    }

    /// The response's items, in the server's sort order (`sortText`, else the label).
    public static func candidates(from response: CompletionResponse) -> [CompletionCandidate] {
        guard let response else { return [] }
        return response.items.map(CompletionCandidate.init(item:)).sorted { ($0.sortText, $0.label) < ($1.sortText, $1.label) }
    }

    private init(item: CompletionItem) {
        // clangd leads labels with a space or a bullet (an include it would insert).
        let label = String(item.label.drop { $0 == " " || $0 == "•" })
        var text = item.insertText ?? label
        var replacing: LSPRange?
        switch item.textEdit {
        case .optionA(let edit):
            text = edit.newText
            replacing = edit.range
        case .optionB(let edit):
            text = edit.newText
            replacing = edit.insert
        case nil:
            break
        }
        if item.insertTextFormat == .snippet { text = SnippetText.plain(text) }
        let documentation: String? = switch item.documentation {
        case .optionA(let string): string
        case .optionB(let content): content.value
        case nil: nil
        }
        self.init(
            label: label, category: Category(item.kind), insertText: text,
            detail: item.detail ?? item.labelDetails.flatMap { $0.detail ?? $0.description },
            documentation: documentation?.isEmpty == false ? documentation : nil, replacing: replacing,
            filterText: item.filterText, sortText: item.sortText, deprecated: item.deprecated ?? false,
            additionalEdits: item.additionalTextEdits ?? [])
    }

    /// The candidates whose filter text holds `prefix`'s characters in order, ignoring case: those starting with it
    /// first, each group in the given order.
    public static func filter(_ candidates: [CompletionCandidate], by prefix: String) -> [CompletionCandidate] {
        guard !prefix.isEmpty else { return candidates }
        let lowered = prefix.lowercased()
        let wanted = Array(lowered)
        var starting: [CompletionCandidate] = []
        var containing: [CompletionCandidate] = []
        for candidate in candidates {
            let text = candidate.filterText.lowercased()
            if text.hasPrefix(lowered) {
                starting.append(candidate)
            } else if isSubsequence(wanted, of: text) {
                containing.append(candidate)
            }
        }
        return starting + containing
    }

    private static func isSubsequence(_ wanted: [Character], of text: String) -> Bool {
        var next = wanted.startIndex
        for character in text where next < wanted.endIndex && character == wanted[next] {
            next += 1
        }
        return next == wanted.endIndex
    }

    /// The edits that accept the completion in `text` (whose lines are `lines`), last first so that each applies to
    /// the text the ones before it left: its text over what was typed — from the start of the server's range, else
    /// `start` (where the word began when the list was asked for), to `cursor` — then its additional edits that end
    /// before that (an import); one that reaches into the typed text is dropped.
    public func edits(
        replacingTypedTextFrom start: Int, to cursor: Int, lines: LineTable, in text: NSString
    ) -> [(range: NSRange, text: String)] {
        let from = min(replacing.map { lines.offset(at: $0.start, in: text) } ?? start, cursor)
        var edits = [(range: NSRange(location: from, length: cursor - from), text: insertText)]
        let others = additionalEdits
            .map { (range: lines.range(of: $0.range, in: text), text: $0.newText) }
            .filter { NSMaxRange($0.range) <= from }
            .sorted { $0.range.location > $1.range.location }
        edits += others
        return edits
    }
}

extension CompletionCandidate.Category {
    init(_ kind: CompletionItemKind?) {
        self = switch kind {
        case .function: .function
        case .method: .method
        case .constructor: .constructor
        case .variable, .value, .reference: .variable
        case .property, .event: .property
        case .field: .field
        case .constant, .unit, .color: .constant
        case .class, .interface, .struct, .enum, .typeParameter: .type
        case .enumMember: .enumMember
        case .module, .file, .folder: .module
        case .keyword, .operator: .keyword
        case .snippet: .snippet
        case .text, nil: .other
        }
    }
}

/// Snippet syntax (LSP's `InsertTextFormat.snippet`, TextMate's) reduced to the text it inserts: tab stops are empty,
/// placeholders and variables their default text, choices their first option, escapes (`\$`, `\}`, `\\`) their
/// character. Lantern asks servers for plain text (`snippetSupport` off); this is for those that send snippets anyway.
public enum SnippetText {
    public static func plain(_ snippet: String) -> String {
        var parser = Parser(Array(snippet))
        return parser.text(until: nil)
    }

    private struct Parser {
        let characters: [Character]
        var index = 0

        init(_ characters: [Character]) {
            self.characters = characters
        }

        /// Text up to `terminator` (consumed) or the end.
        mutating func text(until terminator: Character?) -> String {
            var result = ""
            while index < characters.count {
                let character = characters[index]
                if character == terminator {
                    index += 1
                    return result
                }
                if character == "\\", index + 1 < characters.count, "$}\\,|".contains(characters[index + 1]) {
                    result.append(characters[index + 1])
                    index += 2
                } else if character == "$" {
                    result += element()
                } else {
                    result.append(character)
                    index += 1
                }
            }
            return result
        }

        /// What `$…` at `index` inserts.
        mutating func element() -> String {
            let start = index
            index += 1
            guard index < characters.count else { return "$" }
            let next = characters[index]
            if next.isNumber || next == "_" || next.isLetter {
                // `$1` or `$NAME`: a tab stop or a variable, empty either way.
                while index < characters.count, characters[index].isNumber || characters[index].isLetter || characters[index] == "_" {
                    index += 1
                }
                return ""
            }
            guard next == "{" else {
                index = start + 1
                return "$"
            }
            index += 1
            // `${1}`, `${1:default}`, `${1|a,b|}`, `${NAME}`, `${NAME:default}`.
            while index < characters.count, characters[index].isNumber || characters[index].isLetter || characters[index] == "_" {
                index += 1
            }
            guard index < characters.count else { return "" }
            switch characters[index] {
            case "}":
                index += 1
                return ""
            case ":":
                index += 1
                return text(until: "}")
            case "|":
                index += 1
                let first = text(until: ",")
                // Skip the other choices up to `|}`.
                while index < characters.count, characters[index] != "|" { index += 1 }
                index = min(index + 2, characters.count)
                return first
            default:
                // A transform (`${NAME/regex/format/}`) or something else: skip to the closing brace.
                var depth = 1
                while index < characters.count, depth > 0 {
                    if characters[index] == "{" { depth += 1 }
                    if characters[index] == "}" { depth -= 1 }
                    index += 1
                }
                return ""
            }
        }
    }
}

// MARK: - Capabilities

/// What the editor uses of a server's capabilities (`initialize`).
public struct ServerFeatures: Sendable, Equatable {
    /// The server's name, for the status bar.
    public let name: String
    /// Whether to send `didOpen` and `didClose`.
    public let openClose: Bool
    public let change: TextDocumentSyncKind
    /// Whether to send `didSave`, and with the text.
    public let save: Bool
    public let saveIncludesText: Bool
    public let hover: Bool
    public let definition: Bool
    /// The characters after which the server offers completions; nil without completions.
    public let completionTriggers: [String]?

    public init(_ capabilities: ServerCapabilities, name: String) {
        self.name = name
        switch capabilities.textDocumentSync {
        case .optionA(let options):
            openClose = options.openClose ?? false
            change = options.change ?? .none
            save = options.effectiveSave != nil
            saveIncludesText = options.effectiveSave?.includeText ?? false
        case .optionB(let kind):
            // The older form: a sync kind, with open and close notifications.
            openClose = kind != .none
            change = kind
            save = false
            saveIncludesText = false
        case nil:
            openClose = false
            change = .none
            save = false
            saveIncludesText = false
        }
        hover = Self.isOn(capabilities.hoverProvider)
        definition = Self.isOn(capabilities.definitionProvider)
        completionTriggers = capabilities.completionProvider.map { $0.triggerCharacters ?? [] }
    }

    private static func isOn<Options>(_ provider: TwoTypeOption<Bool, Options>?) -> Bool {
        switch provider {
        case .optionA(let on): on
        case .optionB: true
        case nil: false
        }
    }
}
