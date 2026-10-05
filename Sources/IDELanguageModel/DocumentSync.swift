import Foundation
import LanguageServerProtocol

/// One editor's text as its language server knows it (`textDocument/didOpen`, `didChange`, `didSave`, `didClose`): the
/// document's URI and version, and the lines of the text as it is now, which turn each edit into a change in positions
/// of the text before it.
public struct DocumentSync: Sendable {
    public let uri: DocumentUri
    public let languageId: String
    /// Starts at 1 with `didOpen`; each `didChange` sent counts one more.
    public private(set) var version = 1
    public private(set) var lines: LineTable

    public init(path: String, languageId: String, text: NSString) {
        uri = DocumentURI.uri(forPath: path)
        self.languageId = languageId
        lines = LineTable(text)
    }

    /// `textDocument/didOpen` with `text`, the text the lines describe.
    public func openParams(text: String) -> DidOpenTextDocumentParams {
        DidOpenTextDocumentParams(textDocument: TextDocumentItem(uri: uri, languageId: languageId, version: version, text: text))
    }

    /// The text changed: `range` of the text before was replaced with `newLength` code units, and `text` is the text
    /// after. Returns the `textDocument/didChange` to send as the server syncs (`.incremental`: the replaced range and
    /// what replaced it; `.full`: the whole text), nil when it takes no changes. The lines follow the text either way.
    public mutating func didReplace(
        _ range: NSRange, newLength: Int, in text: NSString, sync: TextDocumentSyncKind
    ) -> DidChangeTextDocumentParams? {
        let change: TextDocumentContentChangeEvent? = switch sync {
        case .incremental:
            TextDocumentContentChangeEvent(
                range: lines.lspRange(of: range), rangeLength: range.length,
                text: text.substring(with: NSRange(location: range.location, length: newLength)))
        case .full:
            TextDocumentContentChangeEvent(range: nil, rangeLength: nil, text: text as String)
        case .none:
            nil
        }
        lines.replace(range, newLength: newLength, in: text)
        guard let change else { return nil }
        version += 1
        return DidChangeTextDocumentParams(uri: uri, version: version, contentChange: change)
    }

    /// `didReplace` as `features`' server takes changes: none without a server, or when it does not have the document
    /// open (`openClose`).
    public mutating func didReplace(
        _ range: NSRange, newLength: Int, in text: NSString, features: ServerFeatures?
    ) -> DidChangeTextDocumentParams? {
        let kind: TextDocumentSyncKind = if let features, features.openClose { features.change } else { .none }
        return didReplace(range, newLength: newLength, in: text, sync: kind)
    }

    /// `textDocument/didSave`, with `text` when the server asks for it.
    public func saveParams(text: String?) -> DidSaveTextDocumentParams {
        DidSaveTextDocumentParams(uri: uri, text: text)
    }

    public var closeParams: DidCloseTextDocumentParams {
        DidCloseTextDocumentParams(uri: uri)
    }
}

/// `file:` URIs for the paths the editor opens, as servers expect them in `textDocument` identifiers.
public enum DocumentURI {
    public static func uri(forPath path: String) -> DocumentUri {
        URL(filePath: path, directoryHint: .notDirectory).absoluteString
    }

    /// The path of a `file:` URI; nil for any other scheme.
    public static func path(of uri: DocumentUri) -> String? {
        guard let url = URL(string: uri), url.isFileURL else { return nil }
        return url.path(percentEncoded: false)
    }
}
