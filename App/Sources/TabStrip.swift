import AppKit
import IDEModel
import IDEState
import SwiftUI

/// The tabs of the workspace on screen, above the detail area: flat, hairline-separated, the selected one attached
/// to the content by sharing its canvas. A press shows a tab at once and a drag moves it along the strip, the others
/// making room (held at a faded edge, the row scrolls); a middle click closes it as its × does. Closing one ends its omp
/// session or terminal, and closing an editor with unsaved edits asks first. The strip's empty end moves the window,
/// and a double click there opens a terminal.
struct TabStrip: View {
    let app: AppState
    let strip: TabLayout.Strip
    /// The pointer over the tabs and the tab being dragged, shared with the scrolling row.
    @State private var interaction = TabInteraction()
    /// The number each session or terminal of the strip carries among those with its title.
    @State private var numbers = TabNumbers()

    /// Widest a tab gets; with many tabs they shrink evenly to `minimumTabWidth`, then the strip scrolls sideways.
    static let maximumTabWidth: CGFloat = 220
    /// Narrowest a tab gets: its icon, close button and a readable part of its title.
    static let minimumTabWidth: CGFloat = 120
    private static let newTabButtonWidth: CGFloat = 28

    var body: some View {
        GeometryReader { geometry in
            let metrics = TabMetrics(available: max(0, geometry.size.width - Self.newTabButtonWidth), count: strip.tabs.count)
            ZStack(alignment: .bottom) {
                Divider()
                // The tabs scroll; + stays outside, right after the last tab or at the strip's end.
                HStack(spacing: 0) {
                    TabScroller(
                        metrics: metrics, tabs: strip.tabs, selected: strip.preferredTab.flatMap(strip.tabs.firstIndex(of:)),
                        interaction: interaction, isDragging: interaction.isDragging, close: { app.closeTab($0) }
                    ) {
                        TabRow(app: app, strip: strip, titles: titles(), width: metrics.width, interaction: interaction)
                    }
                    .frame(width: metrics.viewport)
                    newTabMenu
                        // Pinned at the strip's end while the tabs scroll under their faded edge: a rule sets it off.
                        .overlay(alignment: .leading) {
                            if metrics.scrolls { Chrome.hairline.frame(width: 1) }
                        }
                    Spacer(minLength: 0)
                }
            }
            .background(StripBackground(doubleClick: newTerminal))
        }
        .frame(height: Chrome.tabStripHeight)
        .background(Chrome.surface)
    }

    private var newTabMenu: some View {
        Menu {
            Button("New Session") { app.newSession(in: strip.workspace) }
            Button("New Terminal") { app.newTerminal(in: strip.workspace) }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .medium))
                .frame(width: Self.newTabButtonWidth, height: Chrome.tabStripHeight)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(.secondary)
        .disabled(!app.connection.isConnected)
        .help("New session or terminal in \(AppState.projectName(strip.workspace))")
    }

    /// A double click on the strip's empty end: a terminal in the project, as in Terminal's tab bar.
    private func newTerminal() {
        guard app.connection.isConnected else { return NSSound.beep() }
        app.newTerminal(in: strip.workspace)
    }

    /// Each tab's title: an editor is its file's name; sessions and terminals of the strip with the same title carry a
    /// number from the second on, "tabs — zsh" then "tabs — zsh 2", as Terminal names its windows (`TabNumbers`).
    private func titles() -> [TabKind: String] {
        let titles = Dictionary(uniqueKeysWithValues: strip.tabs.map { ($0, title(of: $0)) })
        let numbered = strip.tabs.filter { $0.editorPath == nil }.sorted { age(of: $0) < age(of: $1) }
        return titles.merging(numbers.titles(of: numbered, titled: titles)) { _, numbered in numbered }
    }

    private func title(of tab: TabKind) -> String {
        switch tab {
        case .session(let key): app.sessionTitle(key)
        case .terminal(let ptyId):
            app.adoptedSession(on: ptyId).map { app.sessionTitle($0.sessionKey) } ?? app.terminals.title(for: ptyId)
        case .editor(let path): (path as NSString).lastPathComponent
        }
    }

    /// Where ompd lists the tab's session or terminal: older first.
    private func age(of tab: TabKind) -> (Int, Int) {
        switch tab {
        case .session(let key): (0, app.connection.sessions.firstIndex { $0.sessionKey == key } ?? .max)
        case .terminal(let ptyId): (1, app.connection.terminals.ptys.firstIndex { $0.ptyId == ptyId } ?? .max)
        case .editor: (2, 0)
        }
    }
}

/// The numbers that tell apart a strip's sessions and terminals of the same title. A tab keeps its number while it is
/// open and its title stays, so no title changes under the user when another tab closes ("zsh 2" stays "zsh 2" once
/// "zsh" is gone); a tab that needs one takes the lowest free, the older first. Number 1 is the title alone.
@MainActor
final class TabNumbers {
    private var assigned: [TabKind: (title: String, number: Int)] = [:]

    /// The numbered titles of `tabs` (older first), whose plain titles are `titles`.
    func titles(of tabs: [TabKind], titled titles: [TabKind: String]) -> [TabKind: String] {
        let open = Set(tabs)
        assigned = assigned.filter { open.contains($0.key) && titles[$0.key] == $0.value.title }
        var result: [TabKind: String] = [:]
        for tab in tabs {
            guard let title = titles[tab] else { continue }
            let number = assigned[tab]?.number ?? {
                let taken = Set(assigned.values.filter { $0.title == title }.map(\.number))
                let free = (1...).first { !taken.contains($0) } ?? 1
                assigned[tab] = (title, free)
                return free
            }()
            result[tab] = number == 1 ? title : "\(title) \(number)"
        }
        return result
    }
}

/// How wide the tabs are and how much of their row shows. They share the strip up to their maximum width; once they
/// would go below their minimum, as many whole tabs as fit show at once and the row scrolls, coming to rest on a tab's
/// edge, so no tab at rest is cut in two (Safari's tab bar).
struct TabMetrics: Equatable {
    let width: CGFloat
    /// The width of the row's visible part.
    let viewport: CGFloat
    let scrolls: Bool

    init(available: CGFloat, count: Int) {
        let count = CGFloat(max(count, 1))
        let shared = (available / count).rounded(.down)
        if shared >= TabStrip.minimumTabWidth {
            width = min(TabStrip.maximumTabWidth, shared)
            viewport = width * count
        } else {
            let shown = max(1, (available / TabStrip.minimumTabWidth).rounded(.down))
            width = max(1, (available / shown).rounded(.down))
            viewport = width * shown
        }
        scrolls = width * count > viewport + 0.5
    }
}

/// What the pointer does to the tabs: the one under it, and the one a press took hold of, which a drag moves along the
/// row.
@MainActor @Observable
final class TabInteraction {
    /// The tab under the pointer; none while a tab is dragged. `SidewaysScrollView` keeps it right.
    var hovered: TabKind?
    private(set) var drag: TabDrag?
    /// A tab moves with the pointer: the row scrolls when it is held at an edge.
    private(set) var isDragging = false
    /// Fresher than ompd's last PTY list: the folder of the terminal under the pointer and what runs in it, for its
    /// tooltip.
    var hoveredTerminal: HoveredTerminal?

    struct HoveredTerminal {
        let ptyId: PTYID
        let cwd: String?
        let running: [String]
    }

    /// How far a press moves sideways before it drags the tab.
    private static let dragDistance: CGFloat = 4

    /// A press on `tab`, at `x` in the row.
    func press(_ tab: TabKind, in order: [TabKind], at x: CGFloat) {
        guard let origin = order.firstIndex(of: tab) else { return }
        drag = TabDrag(tab: tab, order: order, origin: origin, start: x, pointer: x)
    }

    /// The pointer moved to `x` in the row.
    func move(to x: CGFloat) {
        guard var drag, !drag.isDropped else { return }
        drag.pointer = x
        if !drag.isMoving, abs(x - drag.start) >= Self.dragDistance {
            drag.isMoving = true
            isDragging = true
            hovered = nil
        }
        self.drag = drag
    }

    /// The row scrolled under the pointer while it held a tab at an edge.
    func scrolled(by distance: CGFloat) {
        guard isDragging else { return }
        drag?.pointer += distance
    }

    /// The press ended, or SwiftUI called it off. A dragged tab glides into the place it was let go over; `place` puts
    /// it there in the strip, which then ends the drag (`tabsChanged`). Once let go, a tab is not let go again.
    func release(width: CGFloat, place: @escaping (TabKind, Int) -> Void) {
        guard let drag, !drag.isDropped else { return }
        guard drag.isMoving else {
            self.drag = nil
            return
        }
        isDragging = false
        let destination = drag.destination(width: width)
        withAnimation(.easeOut(duration: 0.15)) {
            self.drag?.isDropped = true
        } completion: { [weak self] in
            guard let self, let dropped = self.drag, dropped.isDropped, dropped.tab == drag.tab else { return }
            if destination == drag.origin { self.drag = nil } else { place(drag.tab, destination) }
        }
    }

    /// The strip's tabs changed: a dropped tab is in its place now; a drag under way stops, as its row is gone.
    func tabsChanged() {
        drag = nil
        isDragging = false
    }

    /// How far `tab`, laid out at `index` of the strip's tabs now, shows from there.
    func offset(of tab: TabKind, at index: Int, width: CGFloat) -> CGFloat {
        guard let drag, drag.isMoving, let from = drag.order.firstIndex(of: tab) else { return 0 }
        let x =
            if tab == drag.tab {
                drag.isDropped ? CGFloat(drag.destination(width: width)) * width : drag.leadingEdge(width: width)
            } else {
                CGFloat(from + shift(of: tab, width: width)) * width
            }
        return x - CGFloat(index) * width
    }

    /// The places `tab` moved over to make room for the dragged one: -1, 0 or 1.
    func shift(of tab: TabKind, width: CGFloat) -> Int {
        guard let drag, drag.isMoving, tab != drag.tab, let from = drag.order.firstIndex(of: tab) else { return 0 }
        let destination = drag.destination(width: width)
        if drag.origin < from, from <= destination { return -1 }
        if destination <= from, from < drag.origin { return 1 }
        return 0
    }
}

/// A tab a press took hold of. Every tab shows relative to `order` until the drag is over, whether the strip already
/// has the dropped tab in its new place or not.
struct TabDrag {
    let tab: TabKind
    /// The strip's tabs when the press began.
    let order: [TabKind]
    let origin: Int
    /// The pointer's x in the row (which scrolls with the tabs) when pressed, and now.
    let start: CGFloat
    var pointer: CGFloat
    /// It moved far enough to be dragged; a press that stays put only shows the tab.
    var isMoving = false
    /// Let go: it glides to its place.
    var isDropped = false

    /// The dragged tab's leading edge in the row: where the pointer holds it, within the row.
    func leadingEdge(width: CGFloat) -> CGFloat {
        min(max(CGFloat(origin) * width + pointer - start, 0), CGFloat(order.count - 1) * width)
    }

    /// The place it takes when let go: the one its middle is over.
    func destination(width: CGFloat) -> Int {
        min(max(Int((leadingEdge(width: width) / width).rounded()), 0), order.count - 1)
    }
}

/// The tabs, in the row the strip scrolls.
private struct TabRow: View {
    let app: AppState
    let strip: TabLayout.Strip
    let titles: [TabKind: String]
    let width: CGFloat
    let interaction: TabInteraction

    /// The row's coordinates, which scroll with the tabs: where a drag is measured.
    static let space = "tabs"
    /// The tab a press holds, until the press ends or SwiftUI calls it off (which `onEnded` never hears of).
    @GestureState private var pressed: TabKind?

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(strip.tabs.enumerated()), id: \.element) { index, tab in
                // A terminal running an adopted session stands for that session: its title, status and menu.
                let hosted = tab.ptyId.flatMap(app.adoptedSession(on:))
                let title = titles[tab] ?? ""
                TabItem(
                    tab: tab, title: title, help: help(for: tab, title: title),
                    entry: tab.sessionKey.flatMap(app.entry(for:)) ?? hosted,
                    terminalExited: hosted == nil ? tab.ptyId.map { app.terminals.model($0)?.hasExited == true } : nil,
                    document: tab.editorPath.flatMap(app.editors.document(for:)),
                    isSelected: strip.preferredTab == tab, isHovered: interaction.hovered == tab, width: width,
                    select: { app.selectTab(tab) }, close: { app.closeTab(tab) },
                    press: press(tab)
                )
                .contextMenu { TabMenu(app: app, tab: tab, tabs: strip.tabs) }
                .offset(x: interaction.offset(of: tab, at: index, width: width))
                // The others make room for the dragged tab; it follows the pointer itself.
                .animation(.easeInOut(duration: 0.18), value: interaction.shift(of: tab, width: width))
                .zIndex(interaction.drag?.tab == tab ? 1 : 0)
            }
        }
        .coordinateSpace(name: Self.space)
        .onChange(of: strip.tabs) { interaction.tabsChanged() }
        .onChange(of: pressed) { _, pressed in
            if pressed == nil { release() }
        }
        .task(id: interaction.hovered) { await loadHoveredTerminal() }
    }

    /// Takes hold of `tab` where the mouse goes down, showing it at once (Safari's tabs do not wait for the mouse to come
    /// up), and drags it along once the pointer moves.
    private func press(_ tab: TabKind) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
            .updating($pressed) { _, pressed, _ in pressed = tab }
            .onChanged { value in
                if interaction.drag?.tab != tab || interaction.drag?.isDropped == true {
                    interaction.press(tab, in: strip.tabs, at: value.startLocation.x)
                    app.selectTab(tab)
                }
                interaction.move(to: value.location.x)
            }
            .onEnded { _ in release() }
    }

    private func release() {
        interaction.release(width: width) { tab, index in app.moveTab(tab, to: index) }
    }

    /// The tooltip: an editor's path; a terminal's folder and what runs in it now (its program at the prompt); else the
    /// title.
    private func help(for tab: TabKind, title: String) -> String {
        guard case .terminal(let ptyId) = tab else { return tab.editorPath ?? title }
        let info = app.connection.terminals.info(ptyId)
        let fresh = interaction.hoveredTerminal.flatMap { $0.ptyId == ptyId ? $0 : nil }
        guard let cwd = fresh?.cwd ?? info?.cwd else { return title }
        let path = (StatusBar.displayPath(cwd) as NSString).abbreviatingWithTildeInPath
        let running = fresh?.running ?? []
        guard let command = running.isEmpty ? info.flatMap(Self.program) : running.joined(separator: ", ") else { return path }
        return "\(path) — \(command)"
    }

    /// The terminal's own program as it was started: the login shell by its name, any other command with its arguments.
    private static func program(_ info: PTYInfo) -> String? {
        guard let first = info.command.first else { return nil }
        let name = URL(filePath: first).lastPathComponent
        let arguments = info.command.dropFirst()
        return arguments == ["-l"] ? name : ([name] + arguments).joined(separator: " ")
    }

    /// Asks ompd, once the pointer is over a terminal's tab, where the terminal is and what runs in it.
    private func loadHoveredTerminal() async {
        guard case .terminal(let ptyId)? = interaction.hovered, app.connection.isConnected else { return }
        let running = (try? await app.connection.ptyProcesses(ptyId)) ?? []
        let cwd = (try? await app.connection.listPTYs())?.first { $0.ptyId == ptyId }?.cwd
        // A pointer that moved on cancels this.
        guard !Task.isCancelled else { return }
        interaction.hoveredTerminal = TabInteraction.HoveredTerminal(ptyId: ptyId, cwd: cwd, running: running)
    }
}

/// The row of tabs, `metrics.viewport` wide: scrolls sideways once the tabs reach their minimum width (vertical wheel
/// and trackpad scrolling too, as Xcode's tab bar does), and brings the selected tab into view whenever it changes, a
/// tab opens or closes, or the row resizes.
private struct TabScroller<Content: View>: NSViewRepresentable {
    let metrics: TabMetrics
    let tabs: [TabKind]
    /// Index of the selected tab.
    let selected: Int?
    let interaction: TabInteraction
    let isDragging: Bool
    /// A middle click closes the tab under it.
    let close: (TabKind) -> Void
    let content: Content

    init(
        metrics: TabMetrics, tabs: [TabKind], selected: Int?, interaction: TabInteraction, isDragging: Bool,
        close: @escaping (TabKind) -> Void, @ViewBuilder content: () -> Content
    ) {
        self.metrics = metrics
        self.tabs = tabs
        self.selected = selected
        self.interaction = interaction
        self.isDragging = isDragging
        self.close = close
        self.content = content()
    }

    /// What the selected tab was last brought into view for.
    struct Reveal: Equatable {
        var selected: Int?
        var tabCount: Int
        var metrics: TabMetrics
    }

    final class Coordinator {
        var revealed: Reveal?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> SidewaysScrollView {
        let scrollView = SidewaysScrollView()
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.verticalScrollElasticity = .none
        scrollView.automaticallyAdjustsContentInsets = false
        let hosting = TabRowHostingView(rootView: content)
        // Sized here, by the tabs' count and width.
        hosting.sizingOptions = []
        scrollView.documentView = hosting
        return scrollView
    }

    func updateNSView(_ scrollView: SidewaysScrollView, context: Context) {
        guard let hosting = scrollView.documentView as? TabRowHostingView<Content> else { return }
        hosting.rootView = content
        scrollView.update(tabs: tabs, width: metrics.width, interaction: interaction, close: close)
        hosting.setFrameSize(CGSize(width: metrics.width * CGFloat(tabs.count), height: Chrome.tabStripHeight))
        scrollView.isDragging = isDragging
        let reveal = Reveal(selected: selected, tabCount: tabs.count, metrics: metrics)
        guard !isDragging, reveal != context.coordinator.revealed else { return }
        // Scrolling there shows the way when only the selection moved; a new layout is simply in place.
        let glides = context.coordinator.revealed.map { $0.tabCount == reveal.tabCount && $0.metrics == reveal.metrics } ?? false
        context.coordinator.revealed = reveal
        // Once the scroll view has the size SwiftUI gives it in this pass.
        DispatchQueue.main.async {
            scrollView.settle()
            if let selected { scrollView.reveal(selected, animated: glides) }
        }
    }
}

/// The row's hosting view: a press on a tab of a window in the background shows that tab at once, as in Safari.
private final class TabRowHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// A scroll view that only scrolls sideways: vertical wheel and trackpad motion scrolls it sideways too, a mouse wheel
/// a whole tab per notch, and a scroll comes to rest on a tab's edge. An edge with more tabs beyond it fades out. It
/// also knows which tab the pointer is over (`TabInteraction.hovered`), closes a tab on a middle click, and scrolls
/// while a dragged tab is held at an edge.
private final class SidewaysScrollView: NSScrollView {
    private static let fadeWidth: CGFloat = 24
    /// The most a held drag scrolls per frame.
    private static let autoscrollStep: CGFloat = 14
    private let fade = CAGradientLayer()
    private var tabs: [TabKind] = []
    private var tabWidth: CGFloat = 0
    private weak var interaction: TabInteraction?
    private var close: ((TabKind) -> Void)?
    private var hoverArea: NSTrackingArea?
    private var autoscroll: Timer?
    /// The tab the middle button went down on.
    private var middlePressed: TabKind?

    var isDragging = false {
        didSet {
            guard isDragging != oldValue else { return }
            if isDragging {
                startAutoscroll()
            } else {
                autoscroll?.invalidate()
                autoscroll = nil
                settle(animated: true)
            }
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        fade.startPoint = CGPoint(x: 0, y: 0.5)
        fade.endPoint = CGPoint(x: 1, y: 0.5)
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(liveScrollEnded), name: NSScrollView.didEndLiveScrollNotification, object: self)
        // Where the pointer may be over another tab, or no longer over the strip, without the tracking area hearing of
        // it: a menu closed, the key window or the active app changed.
        for name in [
            NSMenu.didEndTrackingNotification, NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
            NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
        ] {
            center.addObserver(self, selector: #selector(pointerMayHaveMoved), name: name, object: nil)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// The strip laid the row out again. At a new tab width the same tab stays first in view.
    func update(tabs: [TabKind], width: CGFloat, interaction: TabInteraction, close: @escaping (TabKind) -> Void) {
        self.tabs = tabs
        self.interaction = interaction
        self.close = close
        guard width != tabWidth else { return }
        let first = tabWidth > 0 ? (contentView.bounds.minX / tabWidth).rounded() : 0
        tabWidth = width
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scroll(to: first * width, animated: false)
            self.updateHover()
        }
    }

    // MARK: - Scrolling

    private var maximumOffset: CGFloat {
        max(0, (documentView?.frame.width ?? 0) - contentView.bounds.width)
    }

    /// Comes to rest on the nearest tab edge.
    func settle(animated: Bool = false) {
        guard tabWidth > 0 else { return }
        scroll(to: (contentView.bounds.minX / tabWidth).rounded() * tabWidth, animated: animated)
    }

    /// Brings the tab at `index` into view, with a tab of room on the side more tabs are on when the row shows three or
    /// more, so the selected tab is never the one under a faded edge.
    func reveal(_ index: Int, animated: Bool) {
        guard tabWidth > 0 else { return }
        let shown = max(1, Int((contentView.bounds.width / tabWidth).rounded(.down)))
        let last = max(0, tabs.count - shown)
        let room = shown >= 3 ? 1 : 0
        let first = Int((contentView.bounds.minX / tabWidth).rounded())
        let lowest = max(0, min(last, index + room - shown + 1))
        let highest = max(lowest, min(last, index - room))
        scroll(to: CGFloat(min(max(first, lowest), highest)) * tabWidth, animated: animated)
    }

    private func scroll(to x: CGFloat, animated: Bool) {
        let x = min(max(x, 0), maximumOffset)
        guard abs(x - contentView.bounds.minX) > 0.5 else { return }
        let origin = NSPoint(x: x, y: contentView.bounds.minY)
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                contentView.animator().setBoundsOrigin(origin)
            }
        } else {
            contentView.setBoundsOrigin(origin)
        }
        reflectScrolledClipView(contentView)
    }

    /// A trackpad scroll and its momentum ended.
    @objc private func liveScrollEnded(_ notification: Notification) {
        settle(animated: true)
    }

    override func scrollWheel(with event: NSEvent) {
        let vertical = abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX)
        // A mouse wheel's notch: one tab on.
        if !event.hasPreciseScrollingDeltas {
            let delta = vertical ? event.scrollingDeltaY : event.scrollingDeltaX
            guard delta != 0, tabWidth > 0 else { return }
            let first = (contentView.bounds.minX / tabWidth).rounded()
            scroll(to: (first + (delta > 0 ? -1 : 1)) * tabWidth, animated: true)
            return
        }
        guard vertical, let sideways = event.cgEvent?.copy() else {
            super.scrollWheel(with: event)
            return
        }
        // Axis 1 is vertical, axis 2 horizontal, in lines, points and fixed-point lines.
        sideways.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: sideways.getIntegerValueField(.scrollWheelEventDeltaAxis1))
        sideways.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: 0)
        sideways.setIntegerValueField(
            .scrollWheelEventPointDeltaAxis2, value: sideways.getIntegerValueField(.scrollWheelEventPointDeltaAxis1))
        sideways.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: 0)
        sideways.setDoubleValueField(
            .scrollWheelEventFixedPtDeltaAxis2, value: sideways.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1))
        sideways.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: 0)
        super.scrollWheel(with: NSEvent(cgEvent: sideways) ?? event)
    }

    /// While a dragged tab is held within a faded edge (or past it), the row scrolls that way, faster the further out
    /// the pointer is, and the tab goes along.
    private func startAutoscroll() {
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.autoscrollFrame() }
        }
        RunLoop.main.add(timer, forMode: .common)
        autoscroll = timer
    }

    private func autoscrollFrame() {
        guard let window, let interaction else { return }
        let x = convert(window.mouseLocationOutsideOfEventStream, from: nil).x
        let edge = Self.fadeWidth
        let depth = x < edge ? x - edge : x > bounds.width - edge ? x - (bounds.width - edge) : 0
        guard depth != 0 else { return }
        let before = contentView.bounds.minX
        let target = min(max(before + max(-Self.autoscrollStep, min(Self.autoscrollStep, depth / 2)), 0), maximumOffset)
        guard target != before else { return }
        contentView.setBoundsOrigin(NSPoint(x: target, y: contentView.bounds.minY))
        reflectScrolledClipView(contentView)
        interaction.scrolled(by: target - before)
    }

    // MARK: - Fading edges

    /// The view resized.
    override func tile() {
        super.tile()
        updateFade()
    }

    /// The tabs scrolled, or their row grew or shrank.
    override func reflectScrolledClipView(_ clipView: NSClipView) {
        super.reflectScrolledClipView(clipView)
        updateFade()
        updateHover()
    }

    /// Fades the leading edge while tabs are scrolled past it, the trailing one while tabs go on past it.
    private func updateFade() {
        guard let layer, let document = documentView else { return }
        let visible = contentView.bounds
        let before = visible.minX > 0.5
        let after = visible.maxX < document.frame.width - 0.5
        guard before || after, bounds.width > 0 else {
            layer.mask = nil
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let edge = min(Self.fadeWidth / bounds.width, 0.5)
        let opaque = CGColor(gray: 0, alpha: 1)
        let clear = CGColor(gray: 0, alpha: 0)
        fade.frame = layer.bounds
        fade.colors = [before ? clear : opaque, opaque, opaque, after ? clear : opaque]
        fade.locations = [0, NSNumber(value: Double(edge)), NSNumber(value: Double(1 - edge)), 1]
        layer.mask = fade
        CATransaction.commit()
    }

    // MARK: - The pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp, .inVisibleRect], owner: self,
            userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { updateHover() }
    override func mouseMoved(with event: NSEvent) { updateHover() }
    override func mouseExited(with event: NSEvent) { updateHover() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateHover()
    }

    @objc private func pointerMayHaveMoved(_ notification: Notification) {
        updateHover()
    }

    /// The tab under the pointer, read from where the pointer is rather than from the events that led there: an exit
    /// goes missing when a menu opens under the pointer or the window goes away from under it.
    private func updateHover() {
        guard let interaction else { return }
        var hovered: TabKind?
        if let window, window.isVisible, NSApp.isActive, !isDragging, tabWidth > 0,
           NSWindow.windowNumber(at: NSEvent.mouseLocation, belowWindowWithWindowNumber: 0) == window.windowNumber {
            let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            if bounds.contains(point) { hovered = tab(atX: point.x) }
        }
        if interaction.hovered != hovered { interaction.hovered = hovered }
    }

    /// The tab at `x` in the view's coordinates.
    private func tab(atX x: CGFloat) -> TabKind? {
        guard tabWidth > 0 else { return nil }
        let index = Int(((contentView.bounds.minX + x) / tabWidth).rounded(.down))
        return tabs.indices.contains(index) ? tabs[index] : nil
    }

    /// The middle button over the tabs is the strip's, whatever the tabs' views would make of it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        switch NSApp.currentEvent?.type {
        case .otherMouseDown, .otherMouseUp, .otherMouseDragged: frame.contains(point) ? self : nil
        default: super.hitTest(point)
        }
    }

    override func otherMouseDown(with event: NSEvent) {
        middlePressed = event.buttonNumber == 2 ? tab(atX: convert(event.locationInWindow, from: nil).x) : nil
    }

    /// A middle click closes the tab it went down and came up on, as in Safari.
    override func otherMouseUp(with event: NSEvent) {
        defer { middlePressed = nil }
        let point = convert(event.locationInWindow, from: nil)
        guard event.buttonNumber == 2, bounds.contains(point), let tab = tab(atX: point.x), tab == middlePressed else { return }
        close?(tab)
    }
}

/// The strip's empty end. Dragging it moves the window, as dragging a title bar does; a double click runs
/// `doubleClick`.
private struct StripBackground: NSViewRepresentable {
    let doubleClick: () -> Void

    func makeNSView(context: Context) -> StripBackgroundView { StripBackgroundView() }

    func updateNSView(_ view: StripBackgroundView, context: Context) {
        view.doubleClick = doubleClick
    }
}

private final class StripBackgroundView: NSView {
    var doubleClick: () -> Void = {}

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        switch event.clickCount {
        case 1: window?.performDrag(with: event)
        case 2: doubleClick()
        default: break
        }
    }
}

/// Close Tab and the other tabs of the strip, then what the tab's kind allows: Resume or Close Session, Close Terminal,
/// Copy Path and Reveal in Finder.
private struct TabMenu: View {
    let app: AppState
    let tab: TabKind
    /// The tabs of the tab's strip, in order.
    let tabs: [TabKind]

    var body: some View {
        let following = tabs.firstIndex(of: tab).map { Array(tabs[($0 + 1)...]) } ?? []
        Button("Close Tab") { app.closeTab(tab) }
        Button("Close Other Tabs") { app.closeTabs(tabs.filter { $0 != tab }) }
            .disabled(tabs.count < 2)
        Button("Close Tabs to the Right") { app.closeTabs(following) }
            .disabled(following.isEmpty)
        Button("Close All Tabs") { app.closeTabs(tabs) }
        Divider()
        switch tab {
        case .session(let key):
            if let entry = app.entry(for: key) {
                SessionMenu(app: app, entry: entry)
            }
        case .terminal(let ptyId):
            if let hosted = app.adoptedSession(on: ptyId) {
                SessionMenu(app: app, entry: hosted)
                Divider()
            }
            Button("Close Terminal") { app.requestCloseTerminal(ptyId) }
                .disabled(!app.connection.isConnected)
        case .editor(let path):
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(path, forType: .string)
            }
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: path)]) }
        }
    }
}

private struct TabItem<Press: Gesture>: View {
    let tab: TabKind
    let title: String
    let help: String
    /// The session, for a session tab.
    let entry: SessionManifestEntry?
    /// Whether the program ended, for a terminal tab.
    let terminalExited: Bool?
    /// The file an editor tab shows.
    let document: EditorDocument?
    let isSelected: Bool
    let isHovered: Bool
    /// The tab's width, shared out by the strip.
    let width: CGFloat
    let select: () -> Void
    let close: () -> Void
    /// What a press on the tab does, besides `select` for the keyboard and accessibility.
    let press: Press

    var body: some View {
        HStack(spacing: 0) {
            Button(action: select) {
                HStack(spacing: 6) {
                    indicator
                        .frame(width: 12)
                    Text(title)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.leading, 12)
                .padding(.trailing, 6)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .simultaneousGesture(press)
            .help(help)
            .accessibilityLabel("Tab \(title)" + (document?.isDirty == true ? ", edited" : ""))
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(isSelected || isHovered ? 1 : 0)
            .help(tab.ptyId != nil ? "Close Terminal" : document != nil ? "Close Tab" : "Close Session")
            .accessibilityLabel("Close Tab \(title)")
        }
        .font(.system(size: 12))
        .foregroundStyle(isSelected ? .primary : .secondary)
        .padding(.trailing, 6)
        .frame(width: width)
        .frame(maxHeight: .infinity)
        .background(isSelected ? Chrome.canvas : isHovered ? Color.primary.opacity(0.04) : .clear)
        .overlay(alignment: .trailing) { Chrome.hairline.frame(width: 1) }
    }

    @ViewBuilder
    private var indicator: some View {
        if let terminalExited {
            Image(systemName: "terminal")
                .font(.system(size: 10))
                .foregroundStyle(terminalExited ? .tertiary : .secondary)
        } else if let document {
            if document.isDirty {
                Circle().fill(.primary).frame(width: 7, height: 7).help("Unsaved changes")
            } else {
                Image(systemName: "doc.text")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        } else if let status = entry?.status {
            if status.isInProgress {
                ProgressView().controlSize(.mini)
            } else {
                StatusDot(color: status.dotColor, hollow: status == .closed)
            }
        } else {
            StatusDot(color: .secondary, hollow: true)
        }
    }
}
