import CryptoKit
import Foundation
import IDEEditorModel
import Testing

/// A fresh folder under the temp dir, removed when released.
final class TempFolder: Sendable {
    let path: String

    init() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "editor-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        path = url.path(percentEncoded: false).trimmingSuffix("/")
    }

    deinit {
        try? FileManager.default.removeItem(atPath: path)
    }

    func file(_ name: String) -> String { (path as NSString).appendingPathComponent(name) }

    @discardableResult
    func write(_ name: String, _ bytes: [UInt8]) throws -> String {
        let file = file(name)
        try FileManager.default.createDirectory(
            atPath: (file as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(bytes).write(to: URL(filePath: file))
        return file
    }

    @discardableResult
    func write(_ name: String, _ text: String) throws -> String {
        try write(name, Array(text.utf8))
    }

    func mode(_ file: String) throws -> Int {
        try FileManager.default.attributesOfItem(atPath: file)[.posixPermissions] as? Int ?? -1
    }
}

extension String {
    fileprivate func trimmingSuffix(_ suffix: String) -> String {
        hasSuffix(suffix) && count > 1 ? String(dropLast(suffix.count)) : self
    }
}

private func sha256(_ bytes: [UInt8]) -> String {
    SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
}

@Suite struct TextFileTests {
    @Test func textKeepsItsBytesSoItsHashIsTheFilesHash() throws {
        let folder = try TempFolder()
        // A byte order mark, CRLF line ends and decomposed é all survive the round trip.
        let bytes: [UInt8] = [0xEF, 0xBB, 0xBF] + Array("caf\u{65}\u{301}\r\nline 2\r\n".utf8)
        let file = try folder.write("bom.txt", bytes)
        guard case .text(let snapshot) = TextFile.read(file) else {
            Issue.record("not text: \(TextFile.read(file))")
            return
        }
        #expect(Array(snapshot.text.utf8) == bytes)
        #expect(snapshot.hash == sha256(bytes))
        #expect(ContentHash.of(text: snapshot.text) == snapshot.hash)
        #expect(snapshot.utf16Count == (snapshot.text as NSString).length)
    }

    @Test func binaryInvalidUTF8TooLargeFoldersAndMissingFilesAreNotText() throws {
        let folder = try TempFolder()
        #expect(TextFile.read(try folder.write("nul.bin", [0x41, 0x00, 0x42])) == .unsupported(.binary))
        #expect(TextFile.read(try folder.write("latin1.txt", [0x63, 0x61, 0x66, 0xE9])) == .unsupported(.binary))
        let big = try folder.write("big.txt", Array(repeating: 0x61, count: 2048))
        #expect(TextFile.read(big, sizeLimit: 1024) == .unsupported(.tooLarge(bytes: 2048)))
        #expect(TextFile.read(folder.path) == .unsupported(.directory))
        #expect(TextFile.read(folder.file("nope.txt")) == .missing)
        if case .text = TextFile.read(big, sizeLimit: 2048) {} else { Issue.record("a file at the limit is text") }
    }

    @Test func savingReplacesTheFileKeepingItsModeAndReturnsWhatIsOnDisk() throws {
        let folder = try TempFolder()
        let file = try folder.write("run.sh", "#!/bin/sh\necho 1\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o750], ofItemAtPath: file)

        let saved = try TextFile.write("#!/bin/sh\necho 2\n", to: file)
        #expect(try String(contentsOfFile: file, encoding: .utf8) == "#!/bin/sh\necho 2\n")
        #expect(try folder.mode(file) == 0o750)
        #expect(TextFile.read(file) == .text(saved))
        // No temp file is left next to it.
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["run.sh"])
    }

    @Test func savingThroughASymlinkReplacesItsTargetAndKeepsTheLink() throws {
        let folder = try TempFolder()
        let target = try folder.write("real/config.json", "{}\n")
        let link = folder.file("config.json")
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: "real/config.json")

        try TextFile.write("{\"a\": 1}\n", to: link)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link) == "real/config.json")
        #expect(try String(contentsOfFile: target, encoding: .utf8) == "{\"a\": 1}\n")
    }

    @Test func savingCreatesAMissingFileAndRefusesAReadOnlyOne() throws {
        let folder = try TempFolder()
        let created = folder.file("new.txt")
        try TextFile.write("hello\n", to: created)
        #expect(try String(contentsOfFile: created, encoding: .utf8) == "hello\n")

        let locked = try folder.write("locked.txt", "keep\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: locked)
        #expect(throws: TextFile.WriteError.self) { try TextFile.write("changed\n", to: locked) }
        #expect(try String(contentsOfFile: locked, encoding: .utf8) == "keep\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked)
    }
}
