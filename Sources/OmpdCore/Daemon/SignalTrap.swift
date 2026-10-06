import Darwin
import Dispatch

/// Turns process signals into an async stream (`DispatchSource` signal sources, i.e. kqueue `EVFILT_SIGNAL`).
///
/// The signals get a no-op handler rather than `SIG_IGN`: an ignored disposition is inherited across `exec`, so every
/// omp (and every tool process omp starts) would ignore SIGTERM/SIGINT; a caught one reverts to the default in the
/// child. `SA_RESTART` keeps system calls from failing with `EINTR`.
public final class SignalTrap: Sendable {
    /// Every trapped signal, in delivery order.
    public let signals: AsyncStream<Int32>
    private let sources: [any DispatchSourceSignal]

    public init(_ trapped: [Int32], queue: DispatchQueue = DispatchQueue(label: "com.magicelklabs.lantern.ompd.signals")) {
        let (signals, sink) = AsyncStream.makeStream(of: Int32.self)
        self.signals = signals
        sources = trapped.map { signal in
            Self.catchWithoutAction(signal)
            let source = DispatchSource.makeSignalSource(signal: signal, queue: queue)
            source.setEventHandler { sink.yield(signal) }
            source.activate()
            return source
        }
    }

    deinit {
        for source in sources { source.cancel() }
    }

    /// Installs a handler that does nothing (the signal source does the work).
    public static func catchWithoutAction(_ signal: Int32) {
        var action = sigaction()
        action.__sigaction_u.__sa_handler = { _ in }
        action.sa_flags = SA_RESTART
        sigemptyset(&action.sa_mask)
        sigaction(signal, &action, nil)
    }
}
