import Darwin
import Dispatch
import os

/// The exit of a process ompd did not spawn (an omp the user started in one of the IDE's terminals; that terminal's
/// shell reaps it): a kqueue process source, checked once registered as well, since a process that exited before the
/// registration produces no event. `onExit` runs once, on a private queue. Released or `cancel`led, it watches no more.
final class ProcessExitWatch: Sendable {
    private let source: any DispatchSourceProcess

    init(pid: pid_t, onExit: @escaping @Sendable () -> Void) {
        let source = DispatchSource.makeProcessSource(
            identifier: pid, eventMask: .exit, queue: DispatchQueue(label: "com.omp-ide.ompd.exit-watch"))
        self.source = source
        let fired = OSAllocatedUnfairLock(initialState: false)
        let fire = {
            guard fired.withLock({ done in defer { done = true }; return !done }) else { return }
            source.cancel()
            onExit()
        }
        source.setEventHandler(handler: fire)
        source.setRegistrationHandler { if Self.hasExited(pid) { fire() } }
        source.resume()
    }

    deinit { source.cancel() }

    func cancel() { source.cancel() }

    /// `pid` no longer runs: it is gone, or a zombie its parent has not reaped yet.
    static func hasExited(_ pid: pid_t) -> Bool {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return true }
        return info.pbi_status == UInt32(SZOMB)
    }
}
