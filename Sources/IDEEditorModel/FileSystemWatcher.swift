import CoreServices
import Darwin
import Foundation
import os

/// FSEvents for a folder tree (`FSEventStreamCreate` with file-level events): `handler` gets the changed paths in
/// batches, at most one per `latency`, on a private serial queue. Paths are spelled under the folder as given, even
/// when it resolves elsewhere (`/tmp` is `/private/tmp`). Watching stops on `stop()` or when the watcher is released.
public final class FileSystemWatcher: Sendable {
    public struct Change: Equatable, Sendable {
        public var path: String
        /// Something was created, removed or renamed at `path`, so the folder listing it changed.
        public var structural: Bool
        /// Events were dropped or not itemized under `path`: everything below it may have changed.
        public var mustRescan: Bool

        public init(path: String, structural: Bool, mustRescan: Bool) {
            self.path = path
            self.structural = structural
            self.mustRescan = mustRescan
        }
    }

    public let root: String
    /// The running stream; nil once stopped. Created, started and torn down under this lock.
    private let stream: OSAllocatedUnfairLock<FSEventStreamRef?>

    /// Starts watching `root`; nil when it does not exist or FSEvents refuses it.
    public init?(root: String, latency: TimeInterval = 0.2, handler: @escaping @Sendable ([Change]) -> Void) {
        guard let resolved = realpath(root, nil) else { return nil }
        let realRoot = String(cString: resolved)
        free(resolved)
        let box = Delivery(root: root, realRoot: realRoot, handler: handler)
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(box).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<Delivery>.fromOpaque(info).retain()
                return info
            },
            release: { info in
                guard let info else { return }
                Unmanaged<Delivery>.fromOpaque(info).release()
            },
            copyDescription: nil)
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
                | kFSEventStreamCreateFlagWatchRoot)
        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault, Self.callback, &context, [realRoot] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags)
        else { return nil }
        FSEventStreamSetDispatchQueue(created, DispatchQueue(label: "com.magicelklabs.lantern.fsevents", qos: .utility))
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            return nil
        }
        self.root = root
        stream = OSAllocatedUnfairLock(uncheckedState: created)
    }

    deinit {
        stop()
    }

    public func stop() {
        stream.withLockUnchecked { stream in
            guard let running = stream else { return }
            FSEventStreamStop(running)
            FSEventStreamInvalidate(running)
            FSEventStreamRelease(running)
            stream = nil
        }
    }

    /// What the C callback reaches through the stream's `info` pointer; the stream retains it.
    private final class Delivery: Sendable {
        let root: String
        let realRoot: String
        let handler: @Sendable ([Change]) -> Void

        init(root: String, realRoot: String, handler: @escaping @Sendable ([Change]) -> Void) {
            self.root = root
            self.realRoot = realRoot
            self.handler = handler
        }

        func deliver(_ paths: [String], _ flags: UnsafePointer<FSEventStreamEventFlags>) {
            let rescan = FSEventStreamEventFlags(
                kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
                    | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged)
            let structural = FSEventStreamEventFlags(
                kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemRenamed)
            let changes = paths.enumerated().map { index, path in
                Change(
                    path: spelledUnderRoot(path), structural: flags[index] & structural != 0,
                    mustRescan: flags[index] & rescan != 0)
            }
            if !changes.isEmpty { handler(changes) }
        }

        private func spelledUnderRoot(_ path: String) -> String {
            var path = path
            if path.count > 1, path.hasSuffix("/") { path.removeLast() }
            if path == realRoot { return root }
            guard path.hasPrefix(realRoot + "/") else { return path }
            return root + path.dropFirst(realRoot.count)
        }
    }

    private static let callback: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, _ in
        guard let info else { return }
        let delivery = Unmanaged<Delivery>.fromOpaque(info).takeUnretainedValue()
        // `kFSEventStreamCreateFlagUseCFTypes`: a CFArray of CFString.
        let array = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as NSArray
        let paths = array.prefix(count).compactMap { $0 as? String }
        guard paths.count == count else { return }
        delivery.deliver(paths, eventFlags)
    }
}
