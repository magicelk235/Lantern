import Foundation
import IDEProtocol

/// Daemon-side filesystem setup for `AppSupportPaths` (the path layout itself is shared with the app in IDEProtocol).
extension AppSupportPaths {
    /// Creates the layout with every directory at mode 0700, and recreates `run/` empty — unless `keepingRun`: the next
    /// image of an in-place upgrade keeps it (the ownership locks in it are still held, its token is the clients').
    public func prepare(keepingRun: Bool = false) throws {
        try StorageIO.createPrivateDirectory(root)
        if !keepingRun {
            do {
                try FileManager.default.removeItem(at: run)
            } catch CocoaError.fileNoSuchFile {
                // First run.
            }
        }
        for directory in [run, ptySnapshots, hotExit] {
            try StorageIO.createPrivateDirectory(directory)
        }
    }

    /// The client bearer token: the one in `run/token` if valid, else 32 fresh random bytes hex-encoded and
    /// written atomically with mode 0600.
    public func loadOrCreateToken() throws -> String {
        if let data = try StorageIO.readFileIfPresent(token),
            let existing = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
            existing.utf8.count == 64, existing.utf8.allSatisfy({ Self.hexDigits.contains($0) })
        {
            return existing
        }
        var generator = SystemRandomNumberGenerator()
        let fresh = String(
            decoding: (0..<32).flatMap { _ -> [UInt8] in
                let byte = generator.next() as UInt8
                return [Self.hexDigits[Int(byte >> 4)], Self.hexDigits[Int(byte & 0x0F)]]
            },
            as: UTF8.self
        )
        try StorageIO.writeAtomically(Data(fresh.utf8), to: token, mode: 0o600, durable: false)
        return fresh
    }

    private static let hexDigits = Array("0123456789abcdef".utf8)
}
