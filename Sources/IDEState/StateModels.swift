import Foundation

/// One window's layout (table `window`).
public struct WindowState: Equatable, Sendable {
    public var id: String
    /// Width of the sidebar column; nil until the user saw it.
    public var sidebarWidth: Double?
    public var sidebarVisible: Bool
    /// Project folders the user added, in the order they were added (absolute paths). A folder with sessions or tabs
    /// is listed whether or not it is here.
    public var projects: [String]
    /// Detail-area tabs and the tab on screen (so also the selected session).
    public var tabs: TabLayout
    /// The numbers the tabs' titles carry.
    public var tabNumbers: TabNumbers
    /// The projects whose windows are open, in the order of their window tabs; they open again at launch.
    public var windows: [String]
    /// The project whose window tab was in front.
    public var frontWindow: String?

    public init(
        id: String, sidebarWidth: Double? = nil, sidebarVisible: Bool = true,
        projects: [String] = [], tabs: TabLayout = TabLayout(), tabNumbers: TabNumbers = TabNumbers(), windows: [String] = [],
        frontWindow: String? = nil
    ) {
        self.id = id
        self.sidebarWidth = sidebarWidth
        self.sidebarVisible = sidebarVisible
        self.projects = projects
        self.tabs = tabs
        self.tabNumbers = tabNumbers
        self.windows = windows
        self.frontWindow = frontWindow
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

/// Where an editor was in a file (table `editor_ui`): kept after its tab closes, so the file reopens there.
public struct EditorUIState: Equatable, Sendable {
    /// A selected range in UTF-16 units, as `NSRange`; an empty one is a caret.
    public struct Selection: Equatable, Sendable, Codable {
        public var location: Int
        public var length: Int

        public init(location: Int, length: Int) {
            self.location = location
            self.length = length
        }
    }

    /// Absolute path of the file.
    public var path: String
    public var selections: [Selection]
    /// Top-left corner of the visible part of the text, in points.
    public var scrollX: Double
    public var scrollY: Double

    public init(path: String, selections: [Selection] = [], scrollX: Double = 0, scrollY: Double = 0) {
        self.path = path
        self.selections = selections
        self.scrollX = scrollX
        self.scrollY = scrollY
    }
}
