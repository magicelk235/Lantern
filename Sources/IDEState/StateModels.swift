import Foundation
import IDEProtocol

/// A window frame in screen coordinates (AppKit: points, origin at the bottom left of the primary screen).
public struct WindowFrame: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// One window's layout (table `window`).
public struct WindowState: Equatable, Sendable {
    public var id: String
    /// nil until the window was first placed.
    public var frame: WindowFrame?
    /// Width of the sidebar column; nil until the user saw it.
    public var sidebarWidth: Double?
    public var sidebarVisible: Bool
    /// Detail-area tabs and the tab on screen (so also the selected session).
    public var tabs: TabLayout

    public init(
        id: String, frame: WindowFrame? = nil, sidebarWidth: Double? = nil, sidebarVisible: Bool = true,
        tabs: TabLayout = TabLayout()
    ) {
        self.id = id
        self.frame = frame
        self.sidebarWidth = sidebarWidth
        self.sidebarVisible = sidebarVisible
        self.tabs = tabs
    }
}

/// The UI of one session, kept whether or not it has a tab (table `session_ui`).
public struct SessionUIState: Equatable, Sendable {
    public var sessionKey: SessionKey
    /// Unsent composer text.
    public var draft: String
    /// Id of the transcript row at the bottom edge of the viewport; nil while the transcript was scrolled to its end,
    /// where it sticks as new output arrives.
    public var scrollAnchor: String?
    /// Highest journal seq the transcript had applied: a relaunch replays the journal from 0 and knows it has covered
    /// everything that was on screen once it reaches this seq.
    public var lastSeq: Seq

    public init(sessionKey: SessionKey, draft: String = "", scrollAnchor: String? = nil, lastSeq: Seq = 0) {
        self.sessionKey = sessionKey
        self.draft = draft
        self.scrollAnchor = scrollAnchor
        self.lastSeq = lastSeq
    }
}

/// An editor buffer with unsaved edits (table `dirty_buffer`, mirrored to `hot-exit/`).
public struct DirtyBuffer: Equatable, Sendable {
    /// Absolute path of the file the buffer edits: the buffer's identity.
    public var path: String
    /// The whole unsaved text.
    public var contents: String
    /// SHA-256 (lowercase hex) of the file on disk the edits started from, to detect that it changed underneath;
    /// nil for a file that did not exist yet.
    public var baselineHash: String?
    public var updatedAt: Date

    public init(path: String, contents: String, baselineHash: String?, updatedAt: Date = Date()) {
        self.path = path
        self.contents = contents
        self.baselineHash = baselineHash
        self.updatedAt = updatedAt
    }
}
