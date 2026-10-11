import Foundation

/// What a language's `language-configuration.json` says that the editor uses: its comment tokens and its pairs of
/// brackets and quotes.
public struct LanguageConfiguration: Sendable, Hashable {
    /// An opening and a closing token: `(` and `)`, `/*` and `*/`.
    public struct Pair: Sendable, Hashable {
        public let open: String
        public let close: String

        public init(open: String, close: String) {
            self.open = open
            self.close = close
        }
    }

    public let lineComment: String?
    public let blockComment: Pair?
    public let brackets: [Pair]
    /// The pairs whose closing half is typed along with the opening one.
    public let autoClosingPairs: [Pair]
    /// The pairs whose opening half, typed with text selected, wraps the selection in the pair.
    public let surroundingPairs: [Pair]

    public init(
        lineComment: String?, blockComment: Pair?, brackets: [Pair], autoClosingPairs: [Pair], surroundingPairs: [Pair]
    ) {
        self.lineComment = lineComment
        self.blockComment = blockComment
        self.brackets = brackets
        self.autoClosingPairs = autoClosingPairs
        self.surroundingPairs = surroundingPairs
    }

    /// Reads the configuration file at `url`.
    ///
    /// `comments.lineComment` is a string (or, in newer files, an object with a `comment`) and `comments.blockComment`
    /// a pair. A pair is written `[open, close]` or `{ "open": …, "close": … }` (with the `notIn` of an auto-closing
    /// pair, not used here); one that is neither, or has an empty half, is left out. As in VS Code, a file without
    /// `autoClosingPairs` auto-closes its brackets, and one without `surroundingPairs` surrounds with its
    /// auto-closing pairs.
    public static func load(_ url: URL) throws -> LanguageConfiguration {
        guard let object = try JSONC.object(from: Data(contentsOf: url)) as? [String: Any] else {
            throw ExtensionError.unreadable(url.lastPathComponent)
        }
        let comments = object["comments"] as? [String: Any] ?? [:]
        let lineComment: String? = switch comments["lineComment"] {
        case let token as String: token
        case let entry as [String: Any]: entry["comment"] as? String
        default: nil
        }
        let brackets = pairs(object["brackets"]) ?? []
        let autoClosingPairs = pairs(object["autoClosingPairs"]) ?? brackets
        return LanguageConfiguration(
            lineComment: lineComment?.isEmpty == false ? lineComment : nil,
            blockComment: pair(comments["blockComment"]),
            brackets: brackets,
            autoClosingPairs: autoClosingPairs,
            surroundingPairs: pairs(object["surroundingPairs"]) ?? autoClosingPairs)
    }

    /// The pairs of a list; nil when there is no list.
    private static func pairs(_ value: Any?) -> [Pair]? {
        (value as? [Any])?.compactMap { pair($0) }
    }

    private static func pair(_ value: Any?) -> Pair? {
        let halves: (open: Any?, close: Any?) = switch value {
        case let array as [Any] where array.count == 2: (array[0], array[1])
        case let object as [String: Any]: (object["open"], object["close"])
        default: (nil, nil)
        }
        guard let open = halves.open as? String, let close = halves.close as? String,
              !open.isEmpty, !close.isEmpty else { return nil }
        return Pair(open: open, close: close)
    }
}
