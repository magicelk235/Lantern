import Foundation
import LanguageServerProtocol

/// The diagnostics a server published for one file (`textDocument/publishDiagnostics`), still in its positions.
public struct PublishedDiagnostics: Sendable {
    public let path: String
    /// The document version they were found in, when the server says.
    public let version: Int?
    let diagnostics: [Diagnostic]

    public init(path: String, version: Int?, diagnostics: [Diagnostic]) {
        self.path = path
        self.version = version
        self.diagnostics = diagnostics
    }

    /// Whether they were found in a version before `version`, which edits since then make stale (a later
    /// publication follows once the server caught up). Without a version they count as current.
    public func isOlder(than version: Int) -> Bool {
        self.version.map { $0 < version } ?? false
    }

    public func editorDiagnostics(lines: LineTable, in text: NSString) -> [EditorDiagnostic] {
        EditorDiagnostic.map(diagnostics, lines: lines, in: text)
    }
}

/// A problem a language server reported in an editor's text (`textDocument/publishDiagnostics`), at UTF-16 offsets of
/// the text as it is now: published ranges are mapped through the document's lines, and edits move them like markers
/// until the server publishes again.
public struct EditorDiagnostic: Sendable, Hashable {
    public enum Severity: Int, Sendable, Comparable {
        case error = 1
        case warning
        case information
        case hint

        public static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public var range: NSRange
    public let severity: Severity
    public let message: String
    /// Who found it ("sourcekitd", "ts", "Pyright", …), when the server says.
    public let source: String?
    public let code: String?

    public init(range: NSRange, severity: Severity, message: String, source: String? = nil, code: String? = nil) {
        self.range = range
        self.severity = severity
        self.message = message
        self.source = source
        self.code = code
    }

    /// `diagnostics` in `text`, whose lines are `lines`, by where they start. A diagnostic without a severity is an
    /// error (LSP leaves it to the client; VS Code does the same), and ranges are clamped to the text.
    public static func map(_ diagnostics: [Diagnostic], lines: LineTable, in text: NSString) -> [EditorDiagnostic] {
        diagnostics.map { diagnostic in
            let code: String? = switch diagnostic.code {
            case .optionA(let number): String(number)
            case .optionB(let string): string
            case nil: nil
            }
            return EditorDiagnostic(
                range: lines.range(of: diagnostic.range, in: text),
                severity: diagnostic.severity.flatMap { Severity(rawValue: $0.rawValue) } ?? .error,
                message: diagnostic.message, source: diagnostic.source, code: code)
        }
        .sorted { ($0.range.location, $0.severity) < ($1.range.location, $1.severity) }
    }

    /// Where the diagnostic is after `range` of the text was replaced with `newLength` code units. Text inserted at its
    /// end stays outside it, text inserted at its start pushes it along; an edit over its start makes it start where
    /// the edit did, and one over its end makes it end where the inserted text does.
    public func adjusted(replacing range: NSRange, newLength: Int) -> EditorDiagnostic {
        let editStart = range.location
        let oldEnd = NSMaxRange(range)
        let delta = newLength - range.length
        let start = self.range.location
        let end = NSMaxRange(self.range)
        guard end > editStart else { return self }
        var moved = self
        if start >= oldEnd {
            moved.range.location += delta
        } else {
            let newStart = min(start, editStart)
            let newEnd = end >= oldEnd ? end + delta : editStart + newLength
            moved.range = NSRange(location: newStart, length: max(0, newEnd - newStart))
        }
        return moved
    }

    /// The text an underline marks: the range, or for an empty one the character at it (the one before it at a line
    /// break or the end of the text); nil in an empty text.
    public func underline(in text: NSString) -> NSRange? {
        let location = min(range.location, text.length)
        guard range.length == 0 else { return NSRange(location: location, length: min(range.length, text.length - location)) }
        if location < text.length, !Self.isLineBreak(text.character(at: location)) {
            return text.rangeOfComposedCharacterSequence(at: location)
        }
        guard location > 0 else { return nil }
        return text.rangeOfComposedCharacterSequence(at: location - 1)
    }

    private static func isLineBreak(_ unit: unichar) -> Bool {
        unit == 0x0A || unit == 0x0D
    }
}

/// The errors and warnings of one editor, for the status bar (information and hints are not counted).
public struct DiagnosticCounts: Sendable, Equatable {
    public var errors: Int
    public var warnings: Int

    public init(errors: Int, warnings: Int) {
        self.errors = errors
        self.warnings = warnings
    }

    public init(_ diagnostics: [EditorDiagnostic]) {
        self.init(
            errors: diagnostics.count { $0.severity == .error }, warnings: diagnostics.count { $0.severity == .warning })
    }

    public var isEmpty: Bool { errors == 0 && warnings == 0 }
}
