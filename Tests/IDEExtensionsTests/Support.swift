import Foundation
import IDEExtensions

/// A fresh folder under the temp dir, removed when released.
final class TempFolder: Sendable {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appending(path: "extensions-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    /// Writes `text` to `path` in the folder, making the folders on the way.
    @discardableResult
    func write(_ path: String, _ text: String) throws -> URL {
        let file = url.appending(path: path, directoryHint: .notDirectory)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
        return file
    }
}

/// `body` expanded on a line with no indentation, four spaces for a tab, and the variables `values` has.
func expand(
    _ body: String, indentation: String = "", indentUnit: String = "    ", values: [String: String] = [:]
) -> SnippetExpansion {
    SnippetExpander.expand(body, indentation: indentation, indentUnit: indentUnit) { values[$0] }
}

func range(_ location: Int, _ length: Int) -> NSRange {
    NSRange(location: location, length: length)
}
