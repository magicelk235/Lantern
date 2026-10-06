import Darwin
import Foundation
import IDEProtocol
import os

/// When free space on `$APP_SUPPORT`'s volume is low enough to warn about: under 1 GiB, or
/// under 1% of the volume when that is more (4.6 GiB of a 460 GiB disk), or under a fixed threshold (`ompd run
/// --low-space`). One warning per episode: once given, it is re-armed only after free space is back above 1.5 × the
/// threshold, so space hovering around it warns once.
struct LowSpaceAlarm: Sendable {
    static let minimumThreshold: Int64 = 1 << 30

    /// Bytes to warn under; nil: the larger of `minimumThreshold` and 1% of the volume.
    let fixedThreshold: Int64?
    /// The warning was given and not re-armed yet.
    private(set) var warned = false

    init(fixedThreshold: Int64? = nil) {
        self.fixedThreshold = fixedThreshold
    }

    func threshold(volumeBytes: Int64) -> Int64 {
        fixedThreshold ?? max(Self.minimumThreshold, volumeBytes / 100)
    }

    /// A reading of `free` bytes free on a volume of `volumeBytes`: true when it should warn now.
    mutating func observe(free: Int64, volumeBytes: Int64) -> Bool {
        let threshold = threshold(volumeBytes: volumeBytes)
        if warned {
            if free >= threshold + threshold / 2 { warned = false }
            return false
        }
        guard free < threshold else { return false }
        warned = true
        return true
    }
}

/// ompd's watch over its own storage, fed whenever ompd writes to `$APP_SUPPORT` anyway — a
/// manifest write, a pass of PTY snapshot writes — never by a timer: one warning when free space runs low
/// (`LowSpaceAlarm`), and one per streak of failed snapshot passes (a streak ends with a pass whose writes all
/// succeeded). Notices about space carry `DaemonNotice.diskSpaceTopic`.
final class StorageWatch: Sendable {
    private let volume: URL
    private let notify: @Sendable (DaemonNotice) -> Void
    private let state: OSAllocatedUnfairLock<State>

    private struct State: Sendable {
        var alarm: LowSpaceAlarm
        var snapshotsFailing = false
    }

    /// `volume`: a path on the volume to watch (`$APP_SUPPORT`).
    init(volume: URL, alarm: LowSpaceAlarm, notify: @escaping @Sendable (DaemonNotice) -> Void) {
        self.volume = volume
        self.notify = notify
        state = OSAllocatedUnfairLock(initialState: State(alarm: alarm))
    }

    /// Reads the free space and warns when the alarm says so.
    func checkFreeSpace() {
        guard let space = Self.space(at: volume) else { return }
        guard state.withLock({ $0.alarm.observe(free: space.free, volumeBytes: space.total) }) else { return }
        let free = ByteCountFormatter.string(fromByteCount: space.free, countStyle: .file)
        StorageIO.log.error("low disk space: \(free, privacy: .public) free")
        notify(DaemonNotice(
            level: "warning",
            message: "Only \(free) is free on the disk Lantern keeps its data on. Sessions keep running, but omp may fail to save them and terminal screens may not be kept across restarts.",
            at: Date(), topic: DaemonNotice.diskSpaceTopic))
    }

    /// A pass of PTY snapshot writes ended: `failure` is its first failed write, nil when every write succeeded.
    func snapshotsWritten(failure: (any Error)?) {
        checkFreeSpace()
        let starts = state.withLock { s -> Bool in
            defer { s.snapshotsFailing = failure != nil }
            return failure != nil && !s.snapshotsFailing
        }
        guard starts, let failure else { return }
        StorageIO.log.error("terminal snapshots failed: \(String(describing: failure), privacy: .public)")
        notify(DaemonNotice(
            level: "warning",
            message: "Terminal screens could not be saved (\(failure)). Sessions and terminals keep running, but after an ompd restart they may come back with older screens.",
            at: Date(), topic: Self.isOutOfSpace(failure) ? DaemonNotice.diskSpaceTopic : nil))
    }

    /// The write failed because the volume (or the user's quota) is full.
    static func isOutOfSpace(_ error: any Error) -> Bool {
        if case .system(_, _, let code)? = error as? StorageError { return code == ENOSPC || code == EDQUOT }
        if let error = error as? CocoaError { return error.code == .fileWriteOutOfSpace }
        if let error = error as? POSIXError { return error.code == .ENOSPC || error.code == .EDQUOT }
        return false
    }

    /// Free and total bytes of the volume holding `url` (`statfs`); nil when it cannot be read.
    static func space(at url: URL) -> (free: Int64, total: Int64)? {
        var info = statfs()
        guard statfs(url.path(percentEncoded: false), &info) == 0 else { return nil }
        let block = Int64(info.f_bsize)
        return (Int64(info.f_bavail) * block, Int64(info.f_blocks) * block)
    }
}
