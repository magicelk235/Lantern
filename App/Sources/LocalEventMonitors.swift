import AppKit

/// The app's local event monitors (⌘F and ⌃⌘J for editors, ⌘-click, the tab keys, a click on a Files row of a window
/// in the background), kept ahead of every editor's. AppKit calls the newest local monitor first, and each
/// CodeEditSourceEditor `TextViewController` adds one when its view loads that answers ⌘F with the library's own find
/// panel, ⌃⌘J with a beep and ⌃Tab over several lines with an indent, taking the key before the app sees it. An editor
/// that appears calls `moveToFront()`, which adds the app's monitors again, newer than its controller's.
@MainActor
enum LocalEventMonitors {
    private static var handlers: [(mask: NSEvent.EventTypeMask, handle: (NSEvent) -> NSEvent?)] = []
    private static var monitors: [Any] = []

    /// Watches the events of `mask`; `handle` returns the event, or nil when it took it. Monitors added earlier see an
    /// event first.
    static func add(matching mask: NSEvent.EventTypeMask, handle: @escaping (NSEvent) -> NSEvent?) {
        handlers.append((mask, handle))
        moveToFront()
    }

    /// Adds the app's monitors again, so that they come before any added since.
    static func moveToFront() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        // Newest first: the last added here is called first, so the first one goes in last.
        monitors = handlers.reversed().compactMap { NSEvent.addLocalMonitorForEvents(matching: $0.mask, handler: $0.handle) }
    }
}
