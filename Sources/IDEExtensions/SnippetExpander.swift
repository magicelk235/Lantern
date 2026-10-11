import Foundation

/// A snippet as inserted: its text, and the places Tab goes through.
public struct SnippetExpansion: Sendable, Equatable {
    /// One place Tab goes to: the ranges of a placeholder and of its copies, edited together.
    public struct TabStop: Sendable, Equatable {
        /// The snippet's number for it: Tab goes through 1, 2, 3, … and then to 0, where the snippet ends.
        public let index: Int
        /// Where it is in the text, in UTF-16 offsets, first to last; copies of a placeholder share its index.
        public var ranges: [NSRange]

        public init(index: Int, ranges: [NSRange]) {
            self.index = index
            self.ranges = ranges
        }
    }

    public let text: String
    /// In the order Tab visits them, 0 last; every one has at least one range.
    public let tabStops: [TabStop]

    public init(text: String, tabStops: [TabStop]) {
        self.text = text
        self.tabStops = tabStops
    }
}

/// Expands VS Code snippet bodies, written in the TextMate snippet syntax: tab stops `$1` and `${1}`, placeholders
/// `${1:text}` that may hold others, choices `${1|one,two|}` (the first is inserted), variables `$NAME`, `${NAME}` and
/// `${NAME:default}`, and transforms `${NAME/regex/format/flags}` and `${1/regex/format/flags}`. A `\` before `$`, `}`
/// or `\` (and, in a choice, before `,` or `|`) stands for that character. What does not parse is inserted as written,
/// as VS Code does.
public enum SnippetExpander {
    /// The text and tab stops of `body` inserted on a line indented with `indentation`.
    ///
    /// Each line break is followed by `indentation`, and each tab a line of the body starts with becomes `indentUnit`,
    /// so the snippet is indented the way the document is. All placeholders of a number show the text of the first of
    /// them that has some, so `${1:name} = $1` repeats `name`; a placeholder with a transform is the transformed text,
    /// not a stop. `variable` gives a variable's value: an empty value gives way to the variable's default, and a
    /// variable it does not know (nil) is its default, or else its name as a placeholder numbered after the snippet's
    /// own, as in VS Code. A transform's regular expression is matched with `NSRegularExpression`; its format takes
    /// `$1`, `${1}`, `${1:/upcase}` (`downcase`, `capitalize`, `camelcase`, `pascalcase`), `${1:+if}`, `${1:-else}`,
    /// `${1:?if:else}` and `${1:else}`. Without a `$0`, the snippet ends with an empty stop 0 at its end.
    public static func expand(
        _ body: String, indentation: String, indentUnit: String, variable: (String) -> String?
    ) -> SnippetExpansion {
        var parser = SnippetParser(body)
        let nodes = parser.parse()
        return withoutActuallyEscaping(variable) { variable in
            var renderer = SnippetRenderer(nodes, indentation: indentation, indentUnit: indentUnit, variable: variable)
            renderer.render(nodes)
            return renderer.expansion()
        }
    }
}

/// A piece of a parsed snippet body.
private enum SnippetNode {
    /// Text of the body.
    case text(String)
    /// `$1`, `${1}`, `${1:content}`, or a choice, whose content is its first option; content is nil when none is
    /// written.
    case tabStop(Int, content: [SnippetNode]?)
    /// `${1/regex/format/flags}`.
    case transformedTabStop(Int, SnippetTransform)
    /// `$NAME`, `${NAME}` or `${NAME:default}`.
    case variable(String, fallback: [SnippetNode]?)
    /// `${NAME/regex/format/flags}`.
    case transformedVariable(String, SnippetTransform)
}

/// Reads a snippet body into nodes, going back to text where the syntax is wrong as VS Code's snippet parser does.
private struct SnippetParser {
    private let scalars: [Unicode.Scalar]
    private var position = 0

    init(_ body: String) {
        let lines = body.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        scalars = Array(lines.unicodeScalars)
    }

    mutating func parse() -> [SnippetNode] {
        sequence(closable: false).nodes
    }

    private func peek(_ offset: Int = 0) -> Unicode.Scalar? {
        scalars.indices.contains(position + offset) ? scalars[position + offset] : nil
    }

    private mutating func accept(_ scalar: Unicode.Scalar) -> Bool {
        guard peek() == scalar else { return false }
        position += 1
        return true
    }

    /// The nodes up to the end of the body or, when `closable`, to the next `}` not escaped, which is consumed;
    /// `closed` tells which ended them.
    private mutating func sequence(closable: Bool) -> (nodes: [SnippetNode], closed: Bool) {
        var nodes: [SnippetNode] = []
        var text = String.UnicodeScalarView()
        func flush() {
            if !text.isEmpty { nodes.append(.text(String(text))) }
            text = String.UnicodeScalarView()
        }
        while let scalar = peek() {
            if closable, scalar == "}" {
                position += 1
                flush()
                return (nodes, true)
            }
            if scalar == "\\" {
                if let next = peek(1), next == "$" || next == "}" || next == "\\" {
                    text.append(next)
                    position += 2
                } else {
                    text.append(scalar)
                    position += 1
                }
                continue
            }
            if scalar == "$", let parsed = dollar() {
                flush()
                nodes += parsed
                continue
            }
            text.append(scalar)
            position += 1
        }
        flush()
        return (nodes, false)
    }

    /// What the `$` at `position` starts, `position` then past it; nil, with `position` kept, when it starts nothing
    /// and is text.
    private mutating func dollar() -> [SnippetNode]? {
        let start = position
        position += 1
        guard let nodes = afterDollar() else {
            position = start
            return nil
        }
        return nodes
    }

    private mutating func afterDollar() -> [SnippetNode]? {
        if let digits = digits() {
            return Int(digits).map { [.tabStop($0, content: nil)] }
        }
        if let name = name() {
            return [.variable(name, fallback: nil)]
        }
        guard accept("{") else { return nil }
        if let digits = digits() {
            guard let index = Int(digits) else { return nil }
            if accept(":") {
                // Not closed: the text it began with, and what it held.
                let (content, closed) = sequence(closable: true)
                return closed ? [.tabStop(index, content: content)] : [.text("${\(digits):")] + content
            }
            if index > 0, accept("|") {
                return choice().map { [.tabStop(index, content: [.text($0)])] }
            }
            if accept("/") {
                return transform().map { [.transformedTabStop(index, $0)] }
            }
            return accept("}") ? [.tabStop(index, content: nil)] : nil
        }
        guard let name = name() else { return nil }
        if accept(":") {
            let (content, closed) = sequence(closable: true)
            return closed ? [.variable(name, fallback: content)] : [.text("${\(name):")] + content
        }
        if accept("/") {
            return transform().map { [.transformedVariable(name, $0)] }
        }
        return accept("}") ? [.variable(name, fallback: nil)] : nil
    }

    private mutating func digits() -> String? {
        var digits = String.UnicodeScalarView()
        while let scalar = peek(), ("0"..."9").contains(scalar) {
            digits.append(scalar)
            position += 1
        }
        return digits.isEmpty ? nil : String(digits)
    }

    /// A variable name: ASCII letters, digits and `_`, not starting with a digit.
    private mutating func name() -> String? {
        func isLetter(_ scalar: Unicode.Scalar) -> Bool {
            scalar == "_" || ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar)
        }
        guard let first = peek(), isLetter(first) else { return nil }
        var name = String.UnicodeScalarView()
        while let scalar = peek(), isLetter(scalar) || ("0"..."9").contains(scalar) {
            name.append(scalar)
            position += 1
        }
        return String(name)
    }

    /// The first option of a choice whose `|` was just read, `position` then past its closing `|}`; nil when the
    /// options are not closed or one is empty.
    private mutating func choice() -> String? {
        var options: [String] = []
        var option = String.UnicodeScalarView()
        while let scalar = peek() {
            position += 1
            switch scalar {
            case "\\":
                if let next = peek(), next == "," || next == "|" || next == "\\" {
                    option.append(next)
                    position += 1
                } else {
                    option.append(scalar)
                }
            case ",", "|":
                guard !option.isEmpty else { return nil }
                options.append(String(option))
                option = String.UnicodeScalarView()
                if scalar == "|" { return accept("}") ? options.first : nil }
            default:
                option.append(scalar)
            }
        }
        return nil
    }

    /// The transform whose first `/` was just read, `position` then past its `}`; nil when it is not complete or its
    /// regular expression is not one.
    private mutating func transform() -> SnippetTransform? {
        var pattern = String.UnicodeScalarView()
        while true {
            guard let scalar = peek() else { return nil }
            position += 1
            if scalar == "/" { break }
            if scalar == "\\", peek() == "/" {
                pattern.append("/")
                position += 1
            } else {
                pattern.append(scalar)
            }
        }
        var format: [FormatPart] = []
        var literal = String.UnicodeScalarView()
        while true {
            guard let scalar = peek() else { return nil }
            if scalar == "/" {
                position += 1
                break
            }
            if scalar == "$", let group = formatGroup() {
                if !literal.isEmpty { format.append(.text(String(literal))) }
                literal = String.UnicodeScalarView()
                format.append(group)
                continue
            }
            position += 1
            if scalar == "\\", let next = peek(), next == "\\" || next == "/" {
                literal.append(next)
                position += 1
            } else {
                literal.append(scalar)
            }
        }
        if !literal.isEmpty { format.append(.text(String(literal))) }
        var flags = ""
        while true {
            guard let scalar = peek() else { return nil }
            position += 1
            if scalar == "}" { break }
            flags.unicodeScalars.append(scalar)
        }
        return SnippetTransform(pattern: String(pattern), format: format, flags: flags)
    }

    /// The reference to a capture group at the `$` at `position` in a transform's format, `position` then past it;
    /// nil, with `position` kept, when the `$` is text.
    private mutating func formatGroup() -> FormatPart? {
        let start = position
        position += 1
        guard let part = formatGroupAfterDollar() else {
            position = start
            return nil
        }
        return part
    }

    private mutating func formatGroupAfterDollar() -> FormatPart? {
        let braced = accept("{")
        guard let digits = digits(), let group = Int(digits) else { return nil }
        if !braced || accept("}") { return .group(group) }
        guard accept(":") else { return nil }
        if accept("/") {
            guard let name = name(), accept("}") else { return nil }
            return .group(group, shorthand: name)
        }
        if accept("+") {
            guard let ifValue = until("}"), !ifValue.isEmpty else { return nil }
            return .group(group, ifValue: ifValue)
        }
        if accept("?") {
            guard let ifValue = until(":"), !ifValue.isEmpty, let elseValue = until("}"), !elseValue.isEmpty else {
                return nil
            }
            return .group(group, ifValue: ifValue, elseValue: elseValue)
        }
        _ = accept("-")
        guard let elseValue = until("}"), !elseValue.isEmpty else { return nil }
        return .group(group, elseValue: elseValue)
    }

    /// The text up to `delimiter`, which is consumed, a `\` before `$`, `}` or `\` standing for that character; nil
    /// at the end of the body or at any other `\`.
    private mutating func until(_ delimiter: Unicode.Scalar) -> String? {
        var text = String.UnicodeScalarView()
        while let scalar = peek() {
            position += 1
            if scalar == delimiter { return String(text) }
            if scalar == "\\" {
                guard let next = peek(), next == "$" || next == "}" || next == "\\" else { return nil }
                text.append(next)
                position += 1
            } else {
                text.append(scalar)
            }
        }
        return nil
    }
}

/// A piece of a transform's format.
private enum FormatPart {
    case text(String)
    /// A capture group: as matched, changed by a shorthand (`upcase`), or replaced by `ifValue` when it matched
    /// something and by `elseValue` when it did not.
    case group(Int, shorthand: String? = nil, ifValue: String? = nil, elseValue: String? = nil)

    var hasElse: Bool {
        switch self {
        case .text: false
        case .group(_, _, _, let elseValue): elseValue != nil
        }
    }

    func resolve(_ groups: [String]) -> String {
        switch self {
        case .text(let text):
            return text
        case .group(let index, let shorthand, let ifValue, let elseValue):
            let value = groups.indices.contains(index) ? groups[index] : ""
            switch shorthand ?? "" {
            case "upcase": return value.uppercased()
            case "downcase": return value.lowercased()
            case "capitalize": return value.prefix(1).uppercased() + value.dropFirst()
            case "pascalcase": return Self.joinedWords(value, capitalizingFirst: true)
            case "camelcase": return Self.joinedWords(value, capitalizingFirst: false)
            default:
                if !value.isEmpty, let ifValue { return ifValue }
                if value.isEmpty, let elseValue { return elseValue }
                return value
            }
        }
    }

    /// The runs of ASCII letters and digits of `value` run together, each after the first starting in uppercase and
    /// the first in uppercase or lowercase; `value` itself when it has none.
    private static func joinedWords(_ value: String, capitalizingFirst: Bool) -> String {
        let words = value.split { !($0.isASCII && ($0.isLetter || $0.isNumber)) }
        guard !words.isEmpty else { return value }
        return words.enumerated().map { offset, word in
            let first = offset == 0 && !capitalizingFirst ? word.prefix(1).lowercased() : word.prefix(1).uppercased()
            return first + word.dropFirst()
        }.joined()
    }
}

/// A transform's regular expression and format, applied as JavaScript's `String.replace` applies them.
private struct SnippetTransform {
    let regex: NSRegularExpression
    let global: Bool
    let format: [FormatPart]

    /// Nil when `pattern` is not a regular expression or `flags` has letters JavaScript does not know.
    init?(pattern: String, format: [FormatPart], flags: String) {
        guard flags.allSatisfy({ "dgimsuvy".contains($0) }) else { return nil }
        var options: NSRegularExpression.Options = []
        if flags.contains("i") { options.insert(.caseInsensitive) }
        if flags.contains("m") { options.insert(.anchorsMatchLines) }
        if flags.contains("s") { options.insert(.dotMatchesLineSeparators) }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        self.regex = regex
        global = flags.contains("g")
        self.format = format
    }

    /// `value` with its first match, or with the `g` flag every match, replaced by the format; without a match, the
    /// format alone when it has an else branch, else `value` as it is.
    func apply(to value: String) -> String {
        let text = value as NSString
        let whole = NSRange(location: 0, length: text.length)
        let matches = global
            ? regex.matches(in: value, range: whole)
            : regex.firstMatch(in: value, range: whole).map { [$0] } ?? []
        guard !matches.isEmpty else {
            return format.contains(where: \.hasElse) ? resolve([]) : value
        }
        var result = ""
        var end = 0
        for match in matches {
            result += text.substring(with: NSRange(location: end, length: match.range.location - end))
            let groups = (0..<match.numberOfRanges).map { group in
                let range = match.range(at: group)
                return range.location == NSNotFound ? "" : text.substring(with: range)
            }
            result += resolve(groups)
            end = NSMaxRange(match.range)
        }
        return result + text.substring(from: end)
    }

    private func resolve(_ groups: [String]) -> String {
        format.map { $0.resolve(groups) }.joined()
    }
}

/// Writes a parsed snippet out as the text inserted, noting where its tab stops are.
private struct SnippetRenderer {
    private var indentation: String
    private let indentUnit: String
    private let variable: (String) -> String?
    /// The content of each numbered placeholder: that of the first one of its number that has some.
    private let definitions: [Int: [SnippetNode]]
    /// The numbers given to the variables nobody knows, which become placeholders.
    private var unknownVariables: [String: Int] = [:]
    private var nextUnknownIndex: Int
    private var text = String.UnicodeScalarView()
    /// The length of `text` in UTF-16.
    private var length = 0
    private var ranges: [Int: [NSRange]] = [:]
    private var atLineStart = true
    /// The placeholders being written, so one holding a placeholder of its own number does not repeat itself forever.
    private var expanding: Set<Int> = []
    /// Whether the tab stops are noted; not while writing a placeholder's text for a transform.
    private var notesStops = true

    init(_ nodes: [SnippetNode], indentation: String, indentUnit: String, variable: @escaping (String) -> String?) {
        var definitions: [Int: [SnippetNode]] = [:]
        var highest = 0
        func visit(_ nodes: [SnippetNode]) {
            for node in nodes {
                switch node {
                case .text, .transformedVariable:
                    break
                case .tabStop(let index, let content):
                    highest = max(highest, index)
                    if index != 0, let content, !content.isEmpty, definitions[index] == nil {
                        definitions[index] = content
                    }
                    visit(content ?? [])
                case .transformedTabStop(let index, _):
                    highest = max(highest, index)
                case .variable(_, let fallback):
                    visit(fallback ?? [])
                }
            }
        }
        visit(nodes)
        self.indentation = indentation
        self.indentUnit = indentUnit
        self.variable = variable
        self.definitions = definitions
        nextUnknownIndex = highest < Int.max ? highest + 1 : highest
    }

    mutating func render(_ nodes: [SnippetNode]) {
        for node in nodes {
            switch node {
            case .text(let body):
                writeBody(body)
            case .tabStop(let index, let content):
                let start = length
                if index == 0 {
                    render(content ?? [])
                } else if let definition = definitions[index], !expanding.contains(index) {
                    expanding.insert(index)
                    render(definition)
                    expanding.remove(index)
                }
                note(index, from: start)
            case .transformedTabStop(let index, let transform):
                var input = ""
                if let definition = definitions[index], !expanding.contains(index) {
                    expanding.insert(index)
                    input = plainText(definition)
                    expanding.remove(index)
                }
                writeValue(transform.apply(to: input))
            case .variable(let name, let fallback):
                let value = variable(name)
                if let value, !value.isEmpty {
                    writeValue(value)
                } else if let fallback, !fallback.isEmpty {
                    render(fallback)
                } else if value == nil {
                    let index = unknownVariables[name] ?? newUnknownIndex(for: name)
                    let start = length
                    writeBody(name)
                    note(index, from: start)
                }
            case .transformedVariable(let name, let transform):
                writeValue(transform.apply(to: variable(name) ?? ""))
            }
        }
    }

    func expansion() -> SnippetExpansion {
        var ranges = self.ranges
        if ranges[0] == nil { ranges[0] = [NSRange(location: length, length: 0)] }
        let order = ranges.keys.filter { $0 != 0 }.sorted() + [0]
        return SnippetExpansion(text: String(text), tabStops: order.map { index in
            let sorted = ranges[index, default: []].sorted { ($0.location, -$0.length) < ($1.location, -$1.length) }
            return SnippetExpansion.TabStop(index: index, ranges: sorted)
        })
    }

    private mutating func newUnknownIndex(for name: String) -> Int {
        let index = nextUnknownIndex
        unknownVariables[name] = index
        if nextUnknownIndex < Int.max { nextUnknownIndex += 1 }
        return index
    }

    /// `nodes` as text alone, for a transform: no indentation after line breaks, and no stops noted.
    private func plainText(_ nodes: [SnippetNode]) -> String {
        var renderer = self
        renderer.text = String.UnicodeScalarView()
        renderer.length = 0
        renderer.ranges = [:]
        renderer.indentation = ""
        renderer.notesStops = false
        renderer.render(nodes)
        return String(renderer.text)
    }

    private mutating func note(_ index: Int, from start: Int) {
        guard notesStops else { return }
        ranges[index, default: []].append(NSRange(location: start, length: length - start))
    }

    /// Text of the snippet body: a line break is followed by the indentation, and a tab at the start of a line becomes
    /// the indent unit.
    private mutating func writeBody(_ body: String) {
        for scalar in body.unicodeScalars {
            if scalar == "\n" {
                writeLineBreak()
            } else if scalar == "\t", atLineStart {
                for unit in indentUnit.unicodeScalars { write(unit) }
            } else {
                write(scalar)
                atLineStart = false
            }
        }
    }

    /// A variable's value or a transform's result: a line break is followed by the indentation, tabs are kept.
    private mutating func writeValue(_ value: String) {
        let value = value.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        for scalar in value.unicodeScalars {
            if scalar == "\n" {
                writeLineBreak()
            } else {
                write(scalar)
                atLineStart = false
            }
        }
    }

    private mutating func writeLineBreak() {
        write("\n")
        for scalar in indentation.unicodeScalars { write(scalar) }
        atLineStart = true
    }

    private mutating func write(_ scalar: Unicode.Scalar) {
        text.append(scalar)
        length += scalar.value > 0xFFFF ? 2 : 1
    }
}
