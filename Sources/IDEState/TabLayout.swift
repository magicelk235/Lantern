import IDEProtocol

/// What a detail-area tab shows. The value is the tab's identity: a session (later a terminal or a file) has at most
/// one tab per window.
///
/// Stored as `{"kind": …, "id": …}` so the Terminal and Editor slices add their cases (`terminal` ↔ `PTYID`, `editor`
/// ↔ file path) with one more `kind` string. A stored tab whose kind this build does not know is dropped
/// when a `TabLayout` is decoded.
public enum TabKind: Hashable, Sendable {
    /// An omp session's transcript and composer. Closing the tab leaves the session running.
    case session(SessionKey)
    /// A file in the editor, by absolute path. Closing the tab of a buffer with unsaved edits asks first.
    case editor(path: String)
    /// A terminal on one of ompd's PTYs. Closing the tab leaves the PTY running.
    case terminal(PTYID)

    public var sessionKey: SessionKey? {
        switch self {
        case .session(let key): key
        case .editor, .terminal: nil
        }
    }

    public var ptyId: PTYID? {
        switch self {
        case .terminal(let id): id
        case .session, .editor: nil
        }
    }

    public var editorPath: String? {
        if case .editor(let path) = self { path } else { nil }
    }
}

extension TabKind: Codable {
    private enum CodingKeys: String, CodingKey { case kind, id }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "session": self = .session(try container.decode(SessionKey.self, forKey: .id))
        case "editor": self = .editor(path: try container.decode(String.self, forKey: .id))
        case "terminal": self = .terminal(try container.decode(PTYID.self, forKey: .id))
        default:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: "unknown tab kind \(kind)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .session(let key):
            try container.encode("session", forKey: .kind)
            try container.encode(key, forKey: .id)
        case .editor(let path):
            try container.encode("editor", forKey: .kind)
            try container.encode(path, forKey: .id)
        case .terminal(let id):
            try container.encode("terminal", forKey: .kind)
            try container.encode(id, forKey: .id)
        }
    }
}

/// The tabs of a window's detail area: one strip per workspace folder (strips in the order they were first opened,
/// tabs in the order they were opened) and the tab on screen. Every tab is in exactly one strip, and the selection is
/// always an open tab.
public struct TabLayout: Equatable, Sendable {
    public struct Strip: Equatable, Sendable, Identifiable {
        /// The workspace folder the strip's tabs belong to.
        public var workspace: String
        public var tabs: [TabKind]

        public var id: String { workspace }
    }

    public private(set) var strips: [Strip] = []
    /// The tab on screen; its strip is the one the detail area shows.
    public private(set) var selection: TabKind?

    public init() {}

    /// A layout from stored strips, repaired: a tab open twice keeps its first place, strips of the same workspace are
    /// merged, empty strips are dropped and a selection that is not open is cleared.
    init(strips: [Strip], selection: TabKind?) {
        var seen = Set<TabKind>()
        for strip in strips {
            let tabs = strip.tabs.filter { seen.insert($0).inserted }
            if let index = self.strips.firstIndex(where: { $0.workspace == strip.workspace }) {
                self.strips[index].tabs += tabs
            } else if !tabs.isEmpty {
                self.strips.append(Strip(workspace: strip.workspace, tabs: tabs))
            }
        }
        self.selection = selection.flatMap { seen.contains($0) ? $0 : nil }
    }

    /// The strip of the tab on screen.
    public var selectedStrip: Strip? {
        guard let selection else { return nil }
        return strips.first { $0.tabs.contains(selection) }
    }

    /// The session on screen, if the selected tab shows one.
    public var selectedSession: SessionKey? { selection?.sessionKey }

    /// Every open tab, strip by strip.
    public var tabs: [TabKind] { strips.flatMap(\.tabs) }

    public func contains(_ tab: TabKind) -> Bool {
        strips.contains { $0.tabs.contains(tab) }
    }

    /// Shows `tab`. A tab that is not open yet is first appended to the strip of `workspace` (a new strip goes last);
    /// an open tab stays where it is.
    public mutating func open(_ tab: TabKind, in workspace: String) {
        if !contains(tab) {
            if let index = strips.firstIndex(where: { $0.workspace == workspace }) {
                strips[index].tabs.append(tab)
            } else {
                strips.append(Strip(workspace: workspace, tabs: [tab]))
            }
        }
        selection = tab
    }

    /// Shows an open tab; a tab that is not open is ignored.
    public mutating func select(_ tab: TabKind) {
        guard contains(tab) else { return }
        selection = tab
    }

    /// Closes `tab`. When it was on screen its right neighbour in the strip takes its place, else its left one; closing
    /// a strip's last tab removes the strip and leaves nothing on screen.
    public mutating func close(_ tab: TabKind) {
        guard let stripIndex = strips.firstIndex(where: { $0.tabs.contains(tab) }),
              let tabIndex = strips[stripIndex].tabs.firstIndex(of: tab)
        else { return }
        strips[stripIndex].tabs.remove(at: tabIndex)
        let remaining = strips[stripIndex].tabs
        if selection == tab {
            selection = remaining.isEmpty ? nil : remaining[min(tabIndex, remaining.count - 1)]
        }
        if remaining.isEmpty { strips.remove(at: stripIndex) }
    }

    /// Puts `new` where `old` is, selected if `old` was; nothing happens unless `old` is open and `new` is not.
    public mutating func replace(_ old: TabKind, with new: TabKind) {
        guard !contains(new), let stripIndex = strips.firstIndex(where: { $0.tabs.contains(old) }),
              let tabIndex = strips[stripIndex].tabs.firstIndex(of: old)
        else { return }
        strips[stripIndex].tabs[tabIndex] = new
        if selection == old { selection = new }
    }
}

extension TabLayout: Codable {
    private enum CodingKeys: String, CodingKey { case strips, selection }

    private struct StoredStrip: Codable {
        var workspace: String
        var tabs: [StoredTab]
    }

    /// A tab that decodes to nil instead of failing when its kind is unknown (written by a newer build).
    private struct StoredTab: Codable {
        var tab: TabKind?

        init(_ tab: TabKind) { self.tab = tab }

        init(from decoder: any Decoder) throws {
            tab = try? TabKind(from: decoder)
        }

        func encode(to encoder: any Encoder) throws {
            try tab?.encode(to: encoder)
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let strips = try container.decode([StoredStrip].self, forKey: .strips)
        let selection = try container.decodeIfPresent(StoredTab.self, forKey: .selection)?.tab
        self.init(
            strips: strips.map { Strip(workspace: $0.workspace, tabs: $0.tabs.compactMap(\.tab)) },
            selection: selection)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(
            strips.map { StoredStrip(workspace: $0.workspace, tabs: $0.tabs.map(StoredTab.init)) }, forKey: .strips)
        try container.encodeIfPresent(selection.map(StoredTab.init), forKey: .selection)
    }
}
