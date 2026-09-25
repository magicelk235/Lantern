import SwiftUI

/// Completed assistant text as Markdown: fenced code blocks in monospaced boxes, `#` headings, and everything else as
/// paragraphs with inline Markdown (`AttributedString(markdown:)`, whitespace preserved). Parsed off the main thread
/// once per text; the plain text shows until then.
struct MarkdownText: View {
    let text: String
    @State private var parsed: (source: String, blocks: [MarkdownBlock])?

    var body: some View {
        Group {
            if let parsed, parsed.source == text {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(parsed.blocks) { block in
                        view(for: block)
                    }
                }
            } else {
                Text(text).textSelection(.enabled)
            }
        }
        .task(id: text) {
            let source = text
            let blocks = await Task.detached(priority: .userInitiated) { MarkdownBlock.parse(source) }.value
            parsed = (source, blocks)
        }
    }

    @ViewBuilder private func view(for block: MarkdownBlock) -> some View {
        switch block.kind {
        case .prose(let text):
            Text(text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .heading(let level, let text):
            Text(text)
                .font(level <= 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
                .textSelection(.enabled)
                .padding(.top, 4)
        case .code(let language, let code):
            VStack(alignment: .leading, spacing: 4) {
                if let language, !language.isEmpty {
                    Text(language).font(.caption2).foregroundStyle(.secondary)
                }
                ScrollView(.horizontal) {
                    Text(code)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        }
    }
}

struct MarkdownBlock: Identifiable, Sendable {
    enum Kind: Sendable {
        case prose(AttributedString)
        case heading(level: Int, AttributedString)
        case code(language: String?, String)
    }

    let id: Int
    let kind: Kind

    static func parse(_ text: String) -> [MarkdownBlock] {
        var kinds: [Kind] = []
        var prose: [Substring] = []
        var code: (fence: Substring, language: String?, lines: [Substring])?

        func flushProse() {
            let paragraph = prose.joined(separator: "\n").trimmingCharacters(in: .newlines)
            prose = []
            guard !paragraph.isEmpty else { return }
            kinds.append(.prose(inline(paragraph)))
        }

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.drop { $0 == " " }
            if var open = code {
                if trimmed.hasPrefix(open.fence), trimmed.allSatisfy({ $0 == open.fence.first }) {
                    kinds.append(.code(language: open.language, open.lines.joined(separator: "\n")))
                    code = nil
                } else {
                    open.lines.append(line)
                    code = open
                }
            } else if let fence = fence(of: trimmed) {
                flushProse()
                let language = trimmed.dropFirst(fence.count).trimmingCharacters(in: .whitespaces)
                code = (fence, language.isEmpty ? nil : language, [])
            } else if case let (level, title)? = heading(trimmed) {
                flushProse()
                kinds.append(.heading(level: level, inline(String(title))))
            } else {
                prose.append(line)
            }
        }
        if let open = code {
            kinds.append(.code(language: open.language, open.lines.joined(separator: "\n"))) // unterminated fence
        }
        flushProse()
        return kinds.enumerated().map { MarkdownBlock(id: $0.offset, kind: $0.element) }
    }

    private static func fence(of line: Substring) -> Substring? {
        for marker: Character in ["`", "~"] {
            let run = line.prefix { $0 == marker }
            if run.count >= 3 { return run }
        }
        return nil
    }

    private static func heading(_ line: Substring) -> (Int, Substring)? {
        let hashes = line.prefix { $0 == "#" }
        guard (1 ... 6).contains(hashes.count), line.dropFirst(hashes.count).first == " " else { return nil }
        return (hashes.count, line.dropFirst(hashes.count + 1))
    }

    private static func inline(_ markdown: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
        return (try? AttributedString(markdown: markdown, options: options)) ?? AttributedString(markdown)
    }
}
