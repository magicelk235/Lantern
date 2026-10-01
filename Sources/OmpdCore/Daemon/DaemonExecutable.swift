import CryptoKit
import Darwin
import Foundation
import os

/// The process ompd runs in and the ompd executable installed at its path: how ompd moves to that executable
/// when an app update or a rebuild replaced it. `DaemonRunner` provides it; tests substitute their own.
public protocol DaemonProcess: Sendable {
    /// The executable installed at ompd's path, asked what it is (`ompd handover-info`), when it is not the image
    /// running; nil while it is.
    func installedReplacement() async -> InstalledExecutable?

    /// Becomes the installed executable in place, handing `handover` to it (`execve`: the pid, the omp children and the
    /// handed-over descriptors stay). Returns only when that failed, with why; everything is as it was then.
    func handOver(_ handover: DaemonHandover) -> any Error

    /// After the graceful path: becomes the installed executable starting afresh. Does not return: when that fails the
    /// process exits, and launchd's `KeepAlive` starts ompd again.
    func restart() async
}

/// The ompd executable installed at ompd's path, when it differs from the image running.
public struct InstalledExecutable: Sendable, Equatable {
    public var path: String
    /// What it reports; nil when it could not be asked.
    public var version: String?
    /// The handover formats it adopts (`DaemonHandover.format`); empty for an ompd from before the in-place upgrade.
    public var handoverFormats: [Int]
    /// Why it could not be asked (it would not start, was killed, answered nothing usable); nil when it answered.
    public var failure: String?

    public init(path: String, version: String?, handoverFormats: [Int], failure: String? = nil) {
        self.path = path
        self.version = version
        self.handoverFormats = handoverFormats
        self.failure = failure
    }
}

/// `ompd handover-info`: what an ompd executable is, for the image that may hand over to it.
public struct HandoverInfo: Codable, Sendable, Equatable {
    public var version: String
    public var handoverFormats: [Int]

    /// This executable's.
    public static var current: HandoverInfo {
        HandoverInfo(version: ompdVersion, handoverFormats: DaemonHandover.readableFormats)
    }
}

/// The executable this process started from: its path (`proc_pidpath`) and a SHA-256 of the file at start, which tells
/// a replacement (an app update moves a new bundle in, a rebuild relinks) from the image running. Starting the
/// replacement once to ask it is the check that macOS lets this process run it at all (code signature, launch
/// constraints) before ompd hands over to it.
final class RunningExecutable: Sendable {
    let path: String
    private let digest: Data
    /// The last answer, with the file it was about: an unchanged file is not hashed or started again (an app of another
    /// version asks at every connection attempt).
    private let lastCheck = OSAllocatedUnfairLock<(file: FileStamp, installed: InstalledExecutable?)?>(initialState: nil)

    /// How long the replacement gets to answer.
    static let askTimeout: Duration = .seconds(10)

    private init(path: String, digest: Data) {
        self.path = path
        self.digest = digest
    }

    /// Nil when the executable's path or contents cannot be read.
    static func current() -> RunningExecutable? {
        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN)) // PROC_PIDPATHINFO_MAXSIZE
        let length = proc_pidpath(getpid(), &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        let path = String(decoding: buffer[..<Int(length)], as: UTF8.self)
        guard let digest = digest(of: path) else { return nil }
        return RunningExecutable(path: path, digest: digest)
    }

    func installedReplacement() async -> InstalledExecutable? {
        guard let file = FileStamp(path: path) else { return nil }
        if let last = lastCheck.withLock({ $0 }), last.file == file { return last.installed }
        let installed: InstalledExecutable? =
            if let current = Self.digest(of: path), current != digest { await Self.ask(path) } else { nil }
        lastCheck.withLock { $0 = (file, installed) }
        return installed
    }

    /// `ompd handover-info`, else (an ompd from before it) `ompd --version`.
    static func ask(_ path: String) async -> InstalledExecutable {
        do {
            let (reason, status, output) = try await OmpBinary.run(path, arguments: ["handover-info"], timeout: askTimeout)
            if reason == .uncaughtSignal {
                return InstalledExecutable(
                    path: path, version: nil, handoverFormats: [],
                    failure: "it was killed by signal \(status) (\(String(cString: strsignal(status)))) when started here: its code signature or a launch constraint refuses it")
            }
            if reason == .exit, status == 0, let info = try? JSONDecoder().decode(HandoverInfo.self, from: Data(output.utf8)) {
                return InstalledExecutable(path: path, version: info.version, handoverFormats: info.handoverFormats)
            }
            let (_, _, printed) = try await OmpBinary.run(path, arguments: ["--version"], timeout: askTimeout)
            guard let version = printed.firstMatch(of: /ompd (\S+)/)?.1 else {
                return InstalledExecutable(path: path, version: nil, handoverFormats: [], failure: "it is not an ompd it can talk to")
            }
            return InstalledExecutable(path: path, version: String(version), handoverFormats: [])
        } catch OmpBinaryError.timeout {
            return InstalledExecutable(path: path, version: nil, handoverFormats: [], failure: "it did not answer within \(askTimeout)")
        } catch OmpBinaryError.launchFailed(let reason) {
            return InstalledExecutable(path: path, version: nil, handoverFormats: [], failure: "it could not be started: \(reason)")
        } catch {
            return InstalledExecutable(path: path, version: nil, handoverFormats: [], failure: "it could not be started: \(error)")
        }
    }

    private static func digest(of path: String) -> Data? {
        guard let contents = try? Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped) else { return nil }
        return Data(SHA256.hash(data: contents))
    }
}

/// Which file is at a path: device, inode, size and modification time.
struct FileStamp: Sendable, Equatable {
    let device: dev_t
    let inode: ino_t
    let size: off_t
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int

    init?(path: String) {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        device = info.st_dev
        inode = info.st_ino
        size = info.st_size
        modifiedSeconds = info.st_mtimespec.tv_sec
        modifiedNanoseconds = info.st_mtimespec.tv_nsec
    }
}
