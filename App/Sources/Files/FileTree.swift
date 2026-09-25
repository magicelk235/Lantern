import Foundation
import IDEEditorModel

/// The file navigator of one workspace folder: folders are listed when first expanded and listed again when FSEvents
/// says their content changed. Entries git ignores are known so the navigator can dim them.
@MainActor @Observable
final class FileTree {
    let root: String
    /// The entries of each folder listed so far.
    private(set) var children: [String: [FileEntry]] = [:]
    /// Why a folder could not be listed.
    private(set) var failures: [String: String] = [:]
    private(set) var expanded: Set<String> = []
    private(set) var ignored = GitIgnoredPaths.none

    /// The first listing asks for the watcher that keeps the tree current.
    @ObservationIgnored private let startWatching: () -> Void
    @ObservationIgnored private var watching = false
    @ObservationIgnored private var ignoredRefresh: Task<Void, Never>?
    /// A change arrived while `ignoredRefresh` ran: run it once more afterwards.
    @ObservationIgnored private var ignoredStale = false

    init(root: String, startWatching: @escaping () -> Void) {
        self.root = root
        self.startWatching = startWatching
    }

    func isExpanded(_ folder: String) -> Bool { expanded.contains(folder) }

    /// Expanding a folder lists it the first time.
    func setExpanded(_ folder: String, _ isExpanded: Bool) {
        guard isExpanded != expanded.contains(folder) else { return }
        if isExpanded {
            expanded.insert(folder)
            if children[folder] == nil { list(folder) }
        } else {
            expanded.remove(folder)
        }
    }

    func isIgnored(_ path: String) -> Bool {
        ignored.contains(path, under: root)
    }

    /// FSEvents saw these changes under `root`: folders already listed whose content changed are listed again.
    func filesChanged(_ changes: [FileSystemWatcher.Change]) {
        let relevant = changes.filter { !isInsideHiddenFolder($0.path) }
        guard !relevant.isEmpty else { return }
        let rescan = relevant.contains(where: \.mustRescan)
        var folders = Set<String>()
        for change in relevant where change.structural || change.mustRescan {
            folders.insert((change.path as NSString).deletingLastPathComponent)
            folders.insert(change.path)
        }
        let stale = children.keys.filter { folder in
            rescan ? true : folders.contains(folder)
        }
        for folder in stale { list(folder) }
        if !stale.isEmpty || relevant.contains(where: { ($0.path as NSString).lastPathComponent == ".gitignore" }) {
            refreshIgnored()
        }
    }

    private func list(_ folder: String) {
        do {
            let entries = try DirectoryListing.entries(of: folder)
            if children[folder] != entries { children[folder] = entries }
            failures[folder] = nil
        } catch CocoaError.fileReadNoSuchFile where folder != root {
            // Removed: its parent's listing no longer shows it, and nothing below it is listed anymore.
            for listed in children.keys where listed == folder || listed.hasPrefix(folder + "/") {
                children[listed] = nil
                expanded.remove(listed)
            }
        } catch {
            children[folder] = []
            failures[folder] = error.localizedDescription
        }
        if !watching {
            watching = true
            startWatching()
            refreshIgnored()
        }
    }

    /// Asks git again what it ignores; at most one run at a time, and one more if changes came in meanwhile.
    private func refreshIgnored() {
        guard ignoredRefresh == nil else {
            ignoredStale = true
            return
        }
        ignoredRefresh = Task { [root] in
            let ignored = await GitIgnoredPaths.load(in: root)
            if self.ignored != ignored { self.ignored = ignored }
            ignoredRefresh = nil
            if ignoredStale {
                ignoredStale = false
                refreshIgnored()
            }
        }
    }

    private func isInsideHiddenFolder(_ path: String) -> Bool {
        guard path.hasPrefix(root + "/") else { return false }
        return path.dropFirst(root.count + 1).split(separator: "/").dropLast().contains {
            DirectoryListing.hiddenNames.contains(String($0))
        }
    }
}
