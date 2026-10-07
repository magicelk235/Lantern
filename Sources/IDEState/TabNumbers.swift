import IDEProtocol

/// The numbers that tell apart a strip's sessions and terminals of the same title, as Terminal numbers its windows:
/// "zsh", then "zsh 2". Of the tabs that need one, the older takes the lower number, the lowest free; a tab keeps its
/// number while it is open and its title stays, so nothing is renamed under the user when another tab closes ("zsh 2"
/// stays "zsh 2" once "zsh" is gone). Kept in `state.sqlite` with the window's layout: a relaunch shows the numbers it
/// left.
///
/// A title made up while what names a tab is still on its way (ompd's lists at launch, a session's first prompt) is
/// not the tab's own: such a tab shows the title it had last, and a strip hands out no numbers while one of its tabs
/// waits for its title, so the order in which titles arrive decides nothing.
public struct TabNumbers: Equatable, Sendable {
    /// A tab's title and its number among the tabs of its strip with that title.
    public struct Number: Equatable, Sendable {
        public var title: String
        /// 1 is the title alone.
        public var number: Int

        public init(title: String, number: Int) {
            self.title = title
            self.number = number
        }

        /// "zsh 2"; the first is the title alone.
        public var numberedTitle: String { number == 1 ? title : "\(title) \(number)" }
    }

    /// A tab of a strip as it is titled now.
    public struct Tab: Equatable, Sendable {
        public var tab: TabKind
        public var title: String
        /// The title is the tab's own, not one made up while what names the tab is on its way.
        public var isSettled: Bool

        public init(tab: TabKind, title: String, isSettled: Bool) {
            self.tab = tab
            self.title = title
            self.isSettled = isSettled
        }
    }

    public private(set) var numbers: [TabKind: Number]

    public init(_ numbers: [TabKind: Number] = [:]) {
        self.numbers = numbers
    }

    /// The title and number each of a strip's sessions and terminals shows, `tabs` older first. `open`: every tab open
    /// in any strip; a closed tab's number is free again.
    public mutating func numbered(_ tabs: [Tab], open: Set<TabKind>) -> [TabKind: Number] {
        let current = Dictionary(tabs.map { ($0.tab, $0) }, uniquingKeysWith: { first, _ in first })
        numbers = numbers.filter { tab, number in
            guard open.contains(tab) else { return false }
            // A tab of another strip, or one whose title is not settled yet, keeps its number.
            guard let now = current[tab], now.isSettled else { return true }
            return now.title == number.title
        }
        let handsOut = tabs.allSatisfy(\.isSettled)
        var taken: [String: Set<Int>] = [:]
        for tab in tabs {
            if let number = numbers[tab.tab] { taken[number.title, default: []].insert(number.number) }
        }
        var shown: [TabKind: Number] = [:]
        for tab in tabs {
            if let number = numbers[tab.tab] {
                shown[tab.tab] = number
                continue
            }
            let free = (1...).first { !(taken[tab.title]?.contains($0) ?? false) } ?? 1
            taken[tab.title, default: []].insert(free)
            let number = Number(title: tab.title, number: free)
            if handsOut { numbers[tab.tab] = number }
            shown[tab.tab] = number
        }
        return shown
    }

    /// `new` took `old`'s place in its strip (a terminal started again): it carries on with the number.
    public mutating func replace(_ old: TabKind, with new: TabKind) {
        if let number = numbers.removeValue(forKey: old) { numbers[new] = number }
    }
}

extension TabNumbers: Codable {
    /// Stored as `[{"tab": {"kind": …, "id": …}, "title": …, "number": …}]`, sorted for a stable text. A tab whose kind
    /// this build does not know is dropped.
    private struct Stored: Codable {
        var tab: TabKind?
        var title: String
        var number: Int

        private enum CodingKeys: String, CodingKey { case tab, title, number }

        init(tab: TabKind, number: Number) {
            self.tab = tab
            title = number.title
            self.number = number.number
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            tab = try? container.decode(TabKind.self, forKey: .tab)
            title = try container.decode(String.self, forKey: .title)
            number = try container.decode(Int.self, forKey: .number)
        }
    }

    public init(from decoder: any Decoder) throws {
        let stored = try [Stored](from: decoder)
        var numbers: [TabKind: Number] = [:]
        for entry in stored {
            guard let tab = entry.tab, entry.number >= 1 else { continue }
            numbers[tab] = Number(title: entry.title, number: entry.number)
        }
        self.init(numbers)
    }

    public func encode(to encoder: any Encoder) throws {
        try numbers.map { Stored(tab: $0.key, number: $0.value) }
            .sorted { ($0.title, $0.number) < ($1.title, $1.number) }
            .encode(to: encoder)
    }
}
