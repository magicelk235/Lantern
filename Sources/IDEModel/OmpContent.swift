import Foundation
import IDEProtocol

extension JSONValue {
    /// Element `index` of an array; nil when this is not an array or the index is out of range.
    func element(at index: Int) -> JSONValue? {
        guard case .array(let elements) = self, elements.indices.contains(index) else { return nil }
        return elements[index]
    }

    /// Whole-number JSON value as a `Seq`; nil for anything else.
    var seqValue: Seq? {
        guard let number = doubleValue, number >= 0, number < 1.8e19, number.rounded() == number else { return nil }
        return Seq(number)
    }
}

/// Readers for the pieces of omp frames the transcript shows (omp `AgentMessage` content, tool results, arguments).
enum OmpContent {
    /// The text of a message `content`: a plain string, or blocks whose `text` blocks are joined by newlines.
    static func text(of content: JSONValue?) -> String {
        switch content {
        case .string(let text): return text
        case .array(let blocks):
            return blocks.compactMap { $0["type"]?.stringValue == "text" ? $0["text"]?.stringValue : nil }
                .joined(separator: "\n")
        default: return ""
        }
    }

    static func imageCount(of content: JSONValue?) -> Int {
        content?.arrayValue?.count { $0["type"]?.stringValue == "image" } ?? 0
    }

    /// Text of a tool result (`{content: [...], details}`), cut to its last `ToolCall.outputLimit` characters.
    static func toolOutput(_ result: JSONValue?) -> (text: String, truncated: Bool) {
        let text = Self.text(of: result?["content"])
        guard text.count > ToolCall.outputLimit else { return (text, false) }
        return (String(text.suffix(ToolCall.outputLimit)), true)
    }

    /// Argument keys that identify what a call does, most telling first.
    private static let summaryKeys = ["command", "path", "file_path", "url", "pattern", "query", "code", "prompt", "message"]
    private static let summaryLimit = 300

    /// One line saying what a tool call does: its command/path/... argument, the first `ask` question, or compact
    /// JSON of the arguments (without the `i` intent, which is shown separately).
    static func toolSummary(_ arguments: JSONValue?) -> String {
        guard var object = arguments?.objectValue else { return "" }
        object["i"] = nil
        for key in summaryKeys {
            if let value = object[key]?.stringValue, !value.isEmpty { return clip(value) }
        }
        if let question = object["questions"]?.element(at: 0)?["question"]?.stringValue { return clip(question) }
        guard !object.isEmpty else { return "" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(JSONValue.object(object)) else { return "" }
        return clip(String(decoding: data, as: UTF8.self))
    }

    private static func clip(_ text: String) -> String {
        let line = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? ""
        let more = line.count < text.trimmingCharacters(in: .whitespacesAndNewlines).count
        if line.count > summaryLimit { return String(line.prefix(summaryLimit)) + "…" }
        return more ? line + " …" : line
    }
}
