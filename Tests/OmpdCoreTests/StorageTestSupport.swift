import Foundation

/// A fresh directory under the temp dir, removed when the value is released.
final class StorageTempDir: Sendable {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appending(path: "ompd-storage-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    func appendRaw(_ bytes: some Sequence<UInt8>, to file: URL) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(bytes))
    }

    func size(of file: URL) throws -> Int {
        try FileManager.default.attributesOfItem(atPath: file.path(percentEncoded: false))[.size] as? Int ?? -1
    }

    func posixPermissions(of file: URL) throws -> Int {
        try FileManager.default.attributesOfItem(atPath: file.path(percentEncoded: false))[.posixPermissions] as? Int ?? -1
    }
}
