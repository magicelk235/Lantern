import Foundation
import IDEState
import Testing

@Suite struct TabLayoutTests {
    @Test func openingAppendsToTheWorkspaceStripAndReopeningOnlyFocuses() {
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

    @Test func selectingATabThatIsNotOpenChangesNothing() {
        var layout = TabLayout()
        layout.open(.session("a1"), in: "/w/a")
        layout.select(.session("zz"))
        #expect(layout.selectedSession == "a1")
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
              {"workspace": "/w/a", "tabs": [{"kind": "terminal", "id": "pty-1"}, {"kind": "session", "id": "a1"}]},
              {"workspace": "/w/b", "tabs": [{"kind": "notebook", "id": "/w/b/main.ipynb"}]},
              {"workspace": "/w/a", "tabs": [{"kind": "session", "id": "a1"}, {"kind": "session", "id": "a2"}]}
            ],
            "selection": {"kind": "terminal", "id": "pty-1"}}
            """
        let layout = try JSONDecoder().decode(TabLayout.self, from: Data(json.utf8))
        #expect(layout.strips.map(\.workspace) == ["/w/a"])
        #expect(layout.tabs == [.session("a1"), .session("a2")])
        #expect(layout.selection == nil)
    }
}
