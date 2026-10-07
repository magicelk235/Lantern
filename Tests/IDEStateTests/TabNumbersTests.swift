import Foundation
import IDEState
import Testing

@Suite struct TabNumbersTests {
    private func tabs(_ titles: [(String, String)], settled: Bool = true) -> [TabNumbers.Tab] {
        titles.map { TabNumbers.Tab(tab: .terminal($0.0), title: $0.1, isSettled: settled) }
    }

    private func shown(_ numbers: [TabKind: TabNumbers.Number], _ ids: [String]) -> [String] {
        ids.map { numbers[.terminal($0)]?.numberedTitle ?? "-" }
    }

    @Test func theOlderTakesTheLowerNumberAndKeepsItOnceTheOthersAreGone() {
        var numbers = TabNumbers()
        let all = tabs([("p1", "zsh"), ("p2", "zsh"), ("p3", "zsh"), ("p4", "vim")])
        #expect(shown(numbers.numbered(all, open: Set(all.map(\.tab))), ["p1", "p2", "p3", "p4"]) == ["zsh", "zsh 2", "zsh 3", "vim"])

        // "zsh" closes: "zsh 2" stays "zsh 2"; a new one takes the lowest free.
        let rest = tabs([("p2", "zsh"), ("p3", "zsh"), ("p5", "zsh")])
        #expect(shown(numbers.numbered(rest, open: Set(rest.map(\.tab))), ["p2", "p3", "p5"]) == ["zsh 2", "zsh 3", "zsh"])

        // A tab whose title changes gives its number up, and takes one among its new title's.
        let renamed = tabs([("p2", "vim"), ("p3", "zsh"), ("p5", "zsh"), ("p6", "zsh")])
        #expect(shown(numbers.numbered(renamed, open: Set(renamed.map(\.tab))), ["p2", "p3", "p5", "p6"]) == ["vim", "zsh 3", "zsh", "zsh 2"])
    }

    @Test func titlesArrivingOneByOneAtLaunchDecideNothing() {
        // What the last run left: the numbers each tab showed.
        var numbers = TabNumbers([
            .terminal("p1"): .init(title: "app — zsh", number: 1), .terminal("p2"): .init(title: "app — zsh", number: 2),
        ])
        let open: Set<TabKind> = [.terminal("p1"), .terminal("p2"), .terminal("p3")]
        // Nothing is listed yet: each tab shows what it was, and a tab new to the store a number nobody keeps.
        var now = numbers.numbered(tabs([("p1", "Terminal"), ("p2", "Terminal"), ("p3", "Terminal")], settled: false), open: open)
        #expect(shown(now, ["p1", "p2", "p3"]) == ["app — zsh", "app — zsh 2", "Terminal"])

        // The tab on screen hears of its title first: it does not take the lowest number from an older tab.
        var arriving = tabs([("p1", "Terminal"), ("p2", "Terminal"), ("p3", "app — zsh")], settled: false)
        arriving[2].isSettled = true
        now = numbers.numbered(arriving, open: open)
        #expect(shown(now, ["p1", "p2", "p3"]) == ["app — zsh", "app — zsh 2", "app — zsh 3"])
        #expect(numbers.numbers[.terminal("p3")] == nil)

        now = numbers.numbered(tabs([("p1", "app — zsh"), ("p2", "app — zsh"), ("p3", "app — zsh")]), open: open)
        #expect(shown(now, ["p1", "p2", "p3"]) == ["app — zsh", "app — zsh 2", "app — zsh 3"])
        #expect(numbers.numbers[.terminal("p3")]?.number == 3)
    }

    @Test func untitledSessionsComeBackAsTheyWereWhenAnotherOneGetsItsPrompt() {
        let keys = ["s1", "s2", "s3"].map(TabKind.session)
        let open = Set(keys)
        func strip(_ titles: [String], settled: [Bool]) -> [TabNumbers.Tab] {
            zip(keys, zip(titles, settled)).map { TabNumbers.Tab(tab: $0.0, title: $0.1.0, isSettled: $0.1.1) }
        }
        // No numbers kept (a first launch): every session is "New session" until its prompt is read.
        var numbers = TabNumbers()
        _ = numbers.numbered(strip(["New session", "New session", "New session"], settled: [false, true, true]), open: open)
        #expect(numbers.numbers.isEmpty)
        let shown = numbers.numbered(strip(["Fix login", "New session", "New session"], settled: [true, true, true]), open: open)
        #expect(keys.map { shown[$0]?.numberedTitle } == ["Fix login", "New session", "New session 2"])
    }

    @Test func aRestartedTerminalCarriesOnWithItsNumber() {
        var numbers = TabNumbers()
        let open: Set<TabKind> = [.terminal("p1"), .terminal("p2")]
        _ = numbers.numbered(tabs([("p1", "Logs — web"), ("p2", "Logs — web")]), open: open)
        numbers.replace(.terminal("p2"), with: .terminal("p3"))
        // The exited one is listed for a moment longer, as a tab of its own: it does not take the number back.
        let now = numbers.numbered(tabs([("p1", "Logs — web"), ("p3", "Logs — web"), ("p2", "Logs — web")]), open: open.union([.terminal("p3")]))
        #expect(shown(now, ["p1", "p3", "p2"]) == ["Logs — web", "Logs — web 2", "Logs — web 3"])
    }

    @Test func numbersRoundTripAndUnknownTabKindsAreDropped() throws {
        let numbers = TabNumbers([.session("s1"): .init(title: "New session", number: 2), .terminal("p1"): .init(title: "zsh", number: 1)])
        let data = try JSONEncoder().encode(numbers)
        #expect(try JSONDecoder().decode(TabNumbers.self, from: data) == numbers)
        let newer = #"[{"tab":{"kind":"browser","id":"b1"},"title":"x","number":2},{"tab":{"kind":"terminal","id":"p1"},"title":"zsh","number":1}]"#
        #expect(try JSONDecoder().decode(TabNumbers.self, from: Data(newer.utf8)).numbers == [.terminal("p1"): .init(title: "zsh", number: 1)])
    }
}
