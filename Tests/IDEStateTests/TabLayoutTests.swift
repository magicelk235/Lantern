import Foundation
import IDEState
import Testing

@Suite struct TabLayoutTests {
    @Test func openingPutsTheTabInItsWorkspaceStripAndReopeningOnlyFocuses() {
        var layout = TabLayout()
        layout.open(.session("a1"), in: "/w/a")
        layout.open(.session("b1"), in: "/w/b")
        layout.open(.session("a2"), in: "/w/a")
        #expect(layout.strips.map(\.workspace) == ["/w/a", "/w/b"])
        #expect(layout.strips.map(\.tabs) == [[.session("a1"), .session("a2")], [.session("b1")]])
        #expect(layout.selection == .session("a2"))

        // Already open: shown where it is, whatever workspace the caller names.
        layout.open(.session("a1"), in: "/w/b")
        #expect(layout.selection == .session("a1"))
        #expect(layout.selectedStrip?.workspace == "/w/a")
        #expect(layout.tabs == [.session("a1"), .session("a2"), .session("b1")])
    }

    @Test func newTabsGoRightAfterTheTabOnScreenInTheOrderTheyCome() {
        var layout = TabLayout()
        for key in ["a1", "a2", "a3"] { layout.open(.session(key), in: "/w/a") }
        layout.select(.session("a1"))
        layout.open(.session("a4"), in: "/w/a")
        #expect(layout.tabs == ["a1", "a4", "a2", "a3"].map(TabKind.session))

        // Added without being shown (ompd listed them): after the tab on screen, one after another.
        layout.add(.terminal("p1"), in: "/w/a")
        layout.add(.terminal("p2"), in: "/w/a")
        #expect(layout.tabs == [.session("a1"), .session("a4"), .terminal("p1"), .terminal("p2"), .session("a2"), .session("a3")])
        #expect(layout.selection == .session("a4"))

        // Another tab on screen: the next one goes after it.
        layout.select(.session("a3"))
        layout.add(.terminal("p3"), in: "/w/a")
        #expect(layout.tabs.last == .terminal("p3"))
        // A strip that is not on screen takes them after the tab it shows.
        layout.open(.session("b1"), in: "/w/b")
        layout.add(.session("a5"), in: "/w/a")
        #expect(layout.strips[0].tabs.suffix(2) == [.terminal("p3"), .session("a5")])
        #expect(layout.strips[1].tabs == [.session("b1")])
    }

    @Test func aDraggedTabMovesWithinItsStripAndTheOrderIsStored() throws {
        var layout = TabLayout()
        for key in ["a1", "a2", "a3"] { layout.open(.session(key), in: "/w/a") }
        layout.open(.session("b1"), in: "/w/b")
        layout.move(.session("a3"), to: 0)
        #expect(layout.strips[0].tabs == ["a3", "a1", "a2"].map(TabKind.session))
        layout.move(.session("a3"), to: 9)
        #expect(layout.strips[0].tabs == ["a1", "a2", "a3"].map(TabKind.session), "an index past the end is the end")
        layout.move(.session("a1"), to: 1)
        layout.move(.session("zz"), to: 0)
        #expect(layout.strips[0].tabs == ["a2", "a1", "a3"].map(TabKind.session))
        #expect(layout.selection == .session("b1") && layout.strips[1].tabs == [.session("b1")])

        let stored = try JSONDecoder().decode(TabLayout.self, from: JSONEncoder().encode(layout))
        #expect(stored.strips[0].tabs == ["a2", "a1", "a3"].map(TabKind.session))
    }

    @Test func selectingATabThatIsNotOpenChangesNothing() {
        var layout = TabLayout()
        layout.open(.session("a1"), in: "/w/a")
        layout.select(.session("zz"))
        #expect(layout.selectedSession == "a1")
    }

    @Test func eachStripRemembersTheTabItShowedLastAcrossSwitchesClosesAndReloads() throws {
        var layout = TabLayout()
        for key in ["a1", "a2", "a3"] { layout.open(.session(key), in: "/w/a") }
        layout.select(.session("a2"))
        layout.open(.session("b1"), in: "/w/b")
        #expect(layout.strips[0].preferredTab == .session("a2"), "the strip keeps a2 while b is on screen")
        #expect(layout.strips[1].preferredTab == .session("b1"))

        layout.deselect()
        #expect(layout.selection == nil && layout.strips[1].preferredTab == .session("b1"), "an empty detail area forgets nothing")

        layout.close(.session("a2"))
        #expect(layout.strips[0].preferredTab == .session("a3"), "a closed remembered tab hands over to its neighbour")

        let stored = try JSONDecoder().decode(TabLayout.self, from: try JSONEncoder().encode(layout))
        #expect(stored.strips.map(\.preferredTab) == [.session("a3"), .session("b1")])
        let old = Data(#"{"strips":[{"tabs":[{"id":"x","kind":"session"},{"id":"y","kind":"session"}],"workspace":"/w"}]}"#.utf8)
        #expect(try JSONDecoder().decode(TabLayout.self, from: old).strips[0].preferredTab == .session("x"), "layouts without a remembered tab fall back to the first")
    }

    @Test func closingTheShownTabShowsItsRightNeighbourElseItsLeftOne() {
        var layout = TabLayout()
        for key in ["a1", "a2", "a3"] { layout.open(.session(key), in: "/w/a") }
        layout.select(.session("a2"))
        layout.close(.session("a2"))
        #expect(layout.selection == .session("a3"))
        layout.close(.session("a3"))
        #expect(layout.selection == .session("a1"))
        #expect(layout.tabs == [.session("a1")])
    }

    @Test func closingAnotherTabKeepsTheSelectionAndTheLastTabTakesItsStripAlong() {
        var layout = TabLayout()
        layout.open(.session("a1"), in: "/w/a")
        layout.open(.session("b1"), in: "/w/b")
        layout.close(.session("a1"))
        #expect(layout.selection == .session("b1"))
        #expect(layout.strips.map(\.workspace) == ["/w/b"])
        layout.close(.session("b1"))
        #expect(layout.selection == nil)
        #expect(layout.strips.isEmpty)
        layout.close(.session("b1"))
        #expect(layout == TabLayout())
    }

    @Test func decodingDropsUnknownTabKindsAndRepairsWhatIsLeft() throws {
        let json = """
            {"strips": [
              {"workspace": "/w/a", "tabs": [{"kind": "notebook", "id": "n-1"}, {"kind": "session", "id": "a1"}]},
              {"workspace": "/w/b", "tabs": [{"kind": "notebook", "id": "/w/b/main.ipynb"}]},
              {"workspace": "/w/a", "tabs": [{"kind": "session", "id": "a1"}, {"kind": "session", "id": "a2"}]}
            ],
            "selection": {"kind": "notebook", "id": "n-1"}}
            """
        let layout = try JSONDecoder().decode(TabLayout.self, from: Data(json.utf8))
        #expect(layout.strips.map(\.workspace) == ["/w/a"])
        #expect(layout.tabs == [.session("a1"), .session("a2")])
        #expect(layout.selection == nil)
    }

    @Test func terminalTabsPersistAndARestartedTerminalKeepsItsPlace() throws {
        var layout = TabLayout()
        layout.open(.session("a1"), in: "/w/a")
        layout.open(.terminal("pty-1"), in: "/w/a")
        layout.open(.session("a2"), in: "/w/a")
        layout.select(.terminal("pty-1"))
        let restored = try JSONDecoder().decode(TabLayout.self, from: JSONEncoder().encode(layout))
        #expect(restored == layout)

        layout.replace(.terminal("pty-1"), with: .terminal("pty-2"))
        #expect(layout.tabs == [.session("a1"), .terminal("pty-2"), .session("a2")])
        #expect(layout.selection == .terminal("pty-2"))
        layout.replace(.terminal("pty-2"), with: .session("a1"))
        layout.replace(.terminal("pty-9"), with: .terminal("pty-3"))
        #expect(layout.tabs == [.session("a1"), .terminal("pty-2"), .session("a2")], "never duplicates or invents a tab")
    }
}
