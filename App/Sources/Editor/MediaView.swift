import AVFoundation
import AVKit
import AppKit
import ImageIO
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// The files an editor tab shows as what they are rather than as text, by extension: images (ImageIO and SVG through
/// `NSImage`), PDFs (PDFKit), video and audio (AVFoundation).
enum MediaKind: Equatable {
    case image, pdf, video, audio

    /// The kind of the file at `path`; nil for anything else, which opens as text or as the binary notice.
    init?(path: String) {
        switch (path as NSString).pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "jpe", "gif", "heic", "heif", "webp", "avif", "tif", "tiff", "bmp", "ico", "icns",
             "svg", "jp2", "psd":
            self = .image
        case "pdf":
            self = .pdf
        case "mp4", "m4v", "mov", "webm", "3gp":
            self = .video
        case "mp3", "wav", "m4a", "m4b", "aif", "aiff", "aifc", "aac", "caf", "flac":
            self = .audio
        default:
            return nil
        }
    }

    /// The tab's symbol.
    var symbol: String {
        switch self {
        case .image: "photo"
        case .pdf: "doc.richtext"
        case .video: "film"
        case .audio: "waveform"
        }
    }
}

/// What an image or PDF tab zooms with (View › Bigger, Smaller, Actual Size): the view on screen.
@MainActor
protocol MediaZoomable: AnyObject {
    func zoom(_ zoom: Zoom)
}

/// The state of a media tab that outlives its view: the player (so playback keeps its place across tab switches), the
/// zoom, and what the status bar says about the file. The image or page itself is loaded by the view while it shows.
@MainActor @Observable
final class MediaViewer {
    let kind: MediaKind
    private(set) var path: String
    /// Bumped when the file changes on disk: the view loads it again.
    private(set) var revision = 0
    /// What the status bar says: pixel size or length, size on disk, format.
    private(set) var details: [String] = []
    /// A video or audio file AVFoundation cannot play (WebM, say): it gets the binary notice instead.
    private(set) var isUnplayable = false
    /// The zoom of the image or page on screen as a fraction of its actual size; nil while none shows.
    private(set) var scale: CGFloat?
    /// The image or page fits the window, following its size, until the user zooms.
    var fitsWindow = true

    /// How far an image or PDF zooms out and in.
    static let scales: ClosedRange<CGFloat> = 0.05...32

    @ObservationIgnored weak var zoomTarget: (any MediaZoomable)?
    @ObservationIgnored private(set) var player: AVPlayer?
    @ObservationIgnored private var detailsTask: Task<Void, Never>?

    init(path: String, kind: MediaKind) {
        self.path = path
        self.kind = kind
        loadDetails()
    }

    /// The file changed on disk: the view loads it again, playback keeps its place.
    func reload() {
        revision += 1
        loadDetails()
        guard let player else { return }
        let time = player.currentTime()
        player.replaceCurrentItem(with: AVPlayerItem(url: URL(filePath: path)))
        player.seek(to: time)
    }

    /// The file was renamed or moved.
    func move(to newPath: String) {
        path = newPath
        reload()
    }

    /// The tab closed or the file is gone: playback stops and the player lets go of the file.
    func close() {
        detailsTask?.cancel()
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        zoomTarget = nil
    }

    /// The player of a video or audio tab, made the first time it shows. It never starts by itself.
    func makePlayer() -> AVPlayer {
        if let player { return player }
        let player = AVPlayer(url: URL(filePath: path))
        player.actionAtItemEnd = .pause
        self.player = player
        return player
    }

    func pause() {
        player?.pause()
    }

    // MARK: - Zoom

    func allows(_ zoom: Zoom) -> Bool {
        guard let scale else { return false }
        switch zoom {
        case .bigger: return scale < Self.scales.upperBound - 0.001
        case .smaller: return scale > Self.scales.lowerBound + 0.001
        case .actualSize: return true
        }
    }

    func zoom(_ zoom: Zoom) {
        zoomTarget?.zoom(zoom)
    }

    /// The view's zoom changed (or it left the screen: nil).
    func report(scale: CGFloat?) {
        if self.scale != scale { self.scale = scale }
    }

    /// The zoom step after `scale` going in (`up`) or out: Preview's stops.
    static func step(from scale: CGFloat, up: Bool) -> CGFloat {
        let stops: [CGFloat] = [0.05, 0.1, 0.25, 0.33, 0.5, 0.67, 0.75, 1, 1.25, 1.5, 2, 3, 4, 6, 8, 12, 16, 24, 32]
        let next = up ? stops.first { $0 > scale + 0.001 } : stops.last { $0 < scale - 0.001 }
        return next ?? (up ? scales.upperBound : scales.lowerBound)
    }

    // MARK: - Details

    private func loadDetails() {
        detailsTask?.cancel()
        let path = path
        let kind = kind
        detailsTask = Task { [weak self] in
            let (details, unplayable) = await Self.details(of: path, kind: kind)
            guard !Task.isCancelled, let self else { return }
            if self.details != details { self.details = details }
            if isUnplayable != unplayable { isUnplayable = unplayable }
            // The player made while this was still unknown has nothing to play.
            if unplayable, let player {
                player.replaceCurrentItem(with: nil)
                self.player = nil
            }
        }
    }

    /// The status bar's words for the file, and whether AVFoundation can't play it. Read off the main thread.
    private nonisolated static func details(of path: String, kind: MediaKind) async -> ([String], Bool) {
        let url = URL(filePath: path)
        let bytes = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value
        let size = bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
        let format = UTType(filenameExtension: url.pathExtension)?.preferredFilenameExtension?.uppercased()
            ?? url.pathExtension.uppercased()
        switch kind {
        case .image:
            var pixels: String?
            var frames = 1
            if let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 {
                frames = CGImageSourceGetCount(source)
                // An icon holds several sizes: the largest says what it is.
                let largest = (0..<frames).compactMap { index -> (Int, Int)? in
                    let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
                    guard let width = properties?[kCGImagePropertyPixelWidth] as? Int,
                          let height = properties?[kCGImagePropertyPixelHeight] as? Int else { return nil }
                    return (width, height)
                }.max { $0.0 * $0.1 < $1.0 * $1.1 }
                if let largest { pixels = "\(largest.0) × \(largest.1)" }
                // Only an animation's frames are worth counting; an icon's sizes are not frames.
                if UTType(filenameExtension: url.pathExtension)?.conforms(to: .gif) != true { frames = 1 }
            }
            if pixels == nil, let image = NSImage(contentsOf: url), image.size != .zero {
                pixels = "\(Int(image.size.width.rounded())) × \(Int(image.size.height.rounded()))"
            }
            return ([pixels, frames > 1 ? "\(frames) frames" : nil, size, format].compactMap { $0 }, false)
        case .pdf:
            let pages = CGPDFDocument(url as CFURL)?.numberOfPages
            let count = pages.map { $0 == 1 ? "1 page" : "\($0) pages" }
            return ([count, size, format].compactMap { $0 }, false)
        case .video, .audio:
            let asset = AVURLAsset(url: url)
            let playable = (try? await asset.load(.isPlayable)) ?? false
            guard playable else { return ([size, format].compactMap { $0 }, true) }
            let duration = (try? await asset.load(.duration)).flatMap(Self.formatted)
            var dimensions: String?
            if kind == .video, let track = try? await asset.loadTracks(withMediaType: .video).first,
               let loaded = try? await track.load(.naturalSize, .preferredTransform) {
                let shown = loaded.0.applying(loaded.1)
                dimensions = "\(Int(abs(shown.width).rounded())) × \(Int(abs(shown.height).rounded()))"
            }
            return ([duration, dimensions, size, format].compactMap { $0 }, false)
        }
    }

    /// "0:07", "4:32", "1:02:03".
    private nonisolated static func formatted(_ time: CMTime) -> String? {
        guard time.isNumeric else { return nil }
        let seconds = Int(time.seconds.rounded())
        let (hours, minutes, rest) = (seconds / 3600, seconds / 60 % 60, seconds % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, rest)
            : String(format: "%d:%02d", minutes, rest)
    }
}

/// A media tab: the image, the PDF or the player, on the canvas.
struct MediaView: View {
    let app: AppState
    let document: EditorDocument
    let media: MediaViewer

    var body: some View {
        Group {
            switch media.kind {
            case .image:
                ImageCanvas(media: media, revision: media.revision, document: document)
            case .pdf:
                PDFCanvas(media: media, revision: media.revision, document: document)
            case .video, .audio:
                if media.isUnplayable {
                    FileNotice(
                        app: app, document: document, title: "“\(document.name)” can’t be played here",
                        explanation: "macOS can’t play this \(media.kind == .audio ? "audio" : "video") format. Its default app may."
                    )
                } else if media.kind == .audio {
                    VStack(spacing: 18) {
                        Image(systemName: "waveform")
                            .font(.system(size: 56, weight: .light))
                            .foregroundStyle(.secondary)
                        Text(document.name)
                            .font(.title3)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        PlayerCanvas(media: media, revision: media.revision, document: document)
                            .frame(maxWidth: 520)
                            .frame(height: 52)
                    }
                    .padding(32)
                } else {
                    PlayerCanvas(media: media, revision: media.revision, document: document)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Chrome.canvas)
    }
}

/// Gives the view the keyboard when the tab was opened to be typed in (from the navigator, ⌘1…), as an editor's text
/// takes it.
@MainActor
private func focusIfAsked(_ view: NSView, document: EditorDocument) {
    guard document.focusOnAppear else { return }
    document.focusOnAppear = false
    DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
}

// MARK: - Image

private struct ImageCanvas: NSViewRepresentable {
    let media: MediaViewer
    /// Read here so a change on disk updates the view.
    let revision: Int
    let document: EditorDocument

    func makeNSView(context: Context) -> ImageScrollView {
        let view = ImageScrollView(media: media)
        focusIfAsked(view, document: document)
        return view
    }

    func updateNSView(_ view: ImageScrollView, context: Context) {
        view.load(revision: revision)
    }

    static func dismantleNSView(_ view: ImageScrollView, coordinator: ()) {
        view.leave()
    }
}

/// The image, centered on the canvas over a checkerboard where it is transparent; fit to the window until zoomed (⌘+,
/// ⌘-, ⌘0, a pinch, ⌘- or ⌥-scrolling, a two-finger double tap). GIFs animate.
private final class ImageScrollView: NSScrollView, MediaZoomable {
    private let media: MediaViewer
    private let canvas = CheckerboardView()
    private let imageView = NSImageView()
    private var loadedRevision: Int?
    private var boundsObserver: (any NSObjectProtocol)?
    private var magnifyObserver: (any NSObjectProtocol)?
    /// Room left around an image fit to the window.
    private static let margin: CGFloat = 16

    init(media: MediaViewer) {
        self.media = media
        super.init(frame: .zero)
        contentView = CenteringClipView()
        drawsBackground = true
        backgroundColor = Chrome.canvasColor
        hasVerticalScroller = true
        hasHorizontalScroller = true
        autohidesScrollers = true
        allowsMagnification = true
        minMagnification = MediaViewer.scales.lowerBound
        maxMagnification = MediaViewer.scales.upperBound
        imageView.imageScaling = .scaleAxesIndependently
        imageView.animates = true
        imageView.isEditable = false
        imageView.autoresizingMask = [.width, .height]
        canvas.addSubview(imageView)
        documentView = canvas
        contentView.postsBoundsChangedNotifications = true
        boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: contentView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.magnificationDidChange() }
        }
        magnifyObserver = NotificationCenter.default.addObserver(
            forName: NSScrollView.willStartLiveMagnifyNotification, object: self, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.media.fitsWindow = false }
        }
        media.zoomTarget = self
        imageView.setAccessibilityLabel((media.path as NSString).lastPathComponent)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }

    /// Loads the file unless this revision of it shows already.
    func load(revision: Int) {
        guard revision != loadedRevision else { return }
        let first = loadedRevision == nil
        loadedRevision = revision
        // Read now rather than lazily: a later change on disk must not tear the image that shows.
        let image = (try? Data(contentsOf: URL(filePath: media.path))).flatMap(NSImage.init(data:))
        imageView.image = image
        canvas.frame = NSRect(origin: .zero, size: image?.size ?? .zero)
        if first || media.fitsWindow { fit() }
        magnificationDidChange()
    }

    /// The tab left the screen.
    func leave() {
        if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
        if let magnifyObserver { NotificationCenter.default.removeObserver(magnifyObserver) }
        boundsObserver = nil
        magnifyObserver = nil
        imageView.image = nil
        media.report(scale: nil)
    }

    override func layout() {
        super.layout()
        if media.fitsWindow { fit() }
    }

    /// Fits the image in the window, never past its actual size: a small icon stays small.
    private func fit() {
        let size = canvas.frame.size
        let room = contentView.frame.insetBy(dx: Self.margin, dy: Self.margin).size
        guard size.width > 0, size.height > 0, room.width > 0, room.height > 0 else { return }
        let target = max(minMagnification, min(1, room.width / size.width, room.height / size.height))
        if abs(magnification - target) > 0.0001 { magnification = target }
    }

    func zoom(_ zoom: Zoom) {
        switch zoom {
        case .bigger: magnify(to: MediaViewer.step(from: magnification, up: true), at: nil)
        case .smaller: magnify(to: MediaViewer.step(from: magnification, up: false), at: nil)
        case .actualSize: toggleActualSize(at: nil)
        }
    }

    /// Actual size, or back to fitting the window from there.
    private func toggleActualSize(at point: NSPoint?) {
        if !media.fitsWindow, abs(magnification - 1) < 0.001 {
            media.fitsWindow = true
            fit()
        } else {
            magnify(to: 1, at: point)
        }
    }

    /// Zooms to `scale` around `point` (in the image's coordinates), or the middle of what shows.
    private func magnify(to scale: CGFloat, at point: NSPoint?) {
        media.fitsWindow = false
        let bounds = contentView.bounds
        setMagnification(scale, centeredAt: point ?? NSPoint(x: bounds.midX, y: bounds.midY))
    }

    override func scrollWheel(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard modifiers == .command || modifiers == .option else { return super.scrollWheel(with: event) }
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY * 0.01 : event.scrollingDeltaY * 0.1
        guard delta != 0 else { return }
        let point = canvas.convert(event.locationInWindow, from: nil)
        magnify(to: min(max(magnification * exp(delta), minMagnification), maxMagnification), at: point)
    }

    override func smartMagnify(with event: NSEvent) {
        toggleActualSize(at: canvas.convert(event.locationInWindow, from: nil))
    }

    private func magnificationDidChange() {
        guard imageView.image != nil else { return media.report(scale: nil) }
        if canvas.scale != magnification {
            canvas.scale = magnification
            canvas.needsDisplay = true
        }
        media.report(scale: magnification)
    }
}

/// Keeps a document smaller than the view in its middle.
private final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let documentView else { return rect }
        let frame = documentView.frame
        if rect.width > frame.width { rect.origin.x = frame.midX - rect.width / 2 }
        if rect.height > frame.height { rect.origin.y = frame.midY - rect.height / 2 }
        return rect
    }
}

/// The checks behind a transparent image, 8pt on screen whatever the zoom.
private final class CheckerboardView: NSView {
    var scale: CGFloat = 1

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        // Views don't clip to their bounds by default (macOS 14): the dirty rect can reach past them.
        let area = dirtyRect.intersection(bounds)
        guard !area.isEmpty, let context = NSGraphicsContext.current?.cgContext else { return }
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let cell = 8 / max(scale, 0.01)
        context.setFillColor(dark ? CGColor(gray: 0.24, alpha: 1) : CGColor(gray: 1, alpha: 1))
        context.fill(area)
        context.setFillColor(dark ? CGColor(gray: 0.18, alpha: 1) : CGColor(gray: 0.9, alpha: 1))
        let columns = Int((area.minX / cell).rounded(.down))...Int((area.maxX / cell).rounded(.up))
        let rows = Int((area.minY / cell).rounded(.down))...Int((area.maxY / cell).rounded(.up))
        var squares: [CGRect] = []
        squares.reserveCapacity(columns.count * rows.count / 2 + 1)
        for row in rows {
            for column in columns where (row + column) % 2 != 0 {
                squares.append(CGRect(x: CGFloat(column) * cell, y: CGFloat(row) * cell, width: cell, height: cell))
            }
        }
        context.clip(to: area)
        context.fill(squares)
    }
}

// MARK: - PDF

private struct PDFCanvas: NSViewRepresentable {
    let media: MediaViewer
    let revision: Int
    let document: EditorDocument

    func makeNSView(context: Context) -> PDFZoomView {
        let view = PDFZoomView(media: media)
        focusIfAsked(view, document: document)
        return view
    }

    func updateNSView(_ view: PDFZoomView, context: Context) {
        view.load(revision: revision)
    }

    static func dismantleNSView(_ view: PDFZoomView, coordinator: ()) {
        view.leave()
    }
}

/// The PDF's pages one under another, fit to the window's width until zoomed.
private final class PDFZoomView: PDFView, MediaZoomable {
    private let media: MediaViewer
    private var loadedRevision: Int?
    private var scaleObserver: (any NSObjectProtocol)?

    init(media: MediaViewer) {
        self.media = media
        super.init(frame: .zero)
        displayMode = .singlePageContinuous
        displaysPageBreaks = true
        backgroundColor = Chrome.canvasColor
        minScaleFactor = MediaViewer.scales.lowerBound
        maxScaleFactor = MediaViewer.scales.upperBound
        autoScales = media.fitsWindow
        scaleObserver = NotificationCenter.default.addObserver(forName: .PDFViewScaleChanged, object: self, queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.scaleDidChange() }
        }
        media.zoomTarget = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func load(revision: Int) {
        guard revision != loadedRevision else { return }
        loadedRevision = revision
        let page = currentPage.flatMap { document?.index(for: $0) }
        let scale = scaleFactor
        document = PDFDocument(url: URL(filePath: media.path))
        if media.fitsWindow {
            autoScales = true
        } else {
            scaleFactor = scale
        }
        if let page, let target = document?.page(at: min(page, (document?.pageCount ?? 1) - 1)) { go(to: target) }
        scaleDidChange()
    }

    func leave() {
        if let scaleObserver { NotificationCenter.default.removeObserver(scaleObserver) }
        scaleObserver = nil
        document = nil
        media.report(scale: nil)
    }

    func zoom(_ zoom: Zoom) {
        switch zoom {
        case .bigger:
            media.fitsWindow = false
            scaleFactor = MediaViewer.step(from: scaleFactor, up: true)
        case .smaller:
            media.fitsWindow = false
            scaleFactor = MediaViewer.step(from: scaleFactor, up: false)
        case .actualSize:
            if !autoScales, abs(scaleFactor - 1) < 0.001 {
                media.fitsWindow = true
                autoScales = true
            } else {
                media.fitsWindow = false
                scaleFactor = 1
            }
        }
    }

    override func magnify(with event: NSEvent) {
        media.fitsWindow = false
        super.magnify(with: event)
    }

    private func scaleDidChange() {
        media.report(scale: document == nil ? nil : scaleFactor)
    }
}

// MARK: - Video and audio

private struct PlayerCanvas: NSViewRepresentable {
    let media: MediaViewer
    let revision: Int
    let document: EditorDocument

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = media.kind == .audio ? .inline : .floating
        view.showsFullScreenToggleButton = media.kind == .video
        view.allowsPictureInPicturePlayback = media.kind == .video
        view.player = media.makePlayer()
        view.setAccessibilityLabel(document.name)
        focusIfAsked(view, document: document)
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {}

    /// The tab went to the background or closed: playback pauses where it is.
    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player?.pause()
        view.player = nil
    }
}
