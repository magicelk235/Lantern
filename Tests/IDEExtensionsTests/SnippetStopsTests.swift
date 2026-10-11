import Foundation
import IDEExtensions
import Testing

@Suite struct SnippetStopsTests {
    @Test func typingInTheCurrentPlaceholderGrowsItAndMovesTheStopsAfterIt() {
        // "let abc = de" at 10: stop 1 is "abc", stop 2 "de", stop 0 the end.
        var stops = SnippetStops(expand("let ${1:abc} = ${2:de}"), at: 10)
        #expect(stops.primary == range(14, 3))
        let inPrimary = stops.replace(range(15, 1), newLength: 3)
        #expect(inPrimary)
        #expect(stops.primary == range(14, 5))
        let toSecond = stops.advance(by: 1)
        #expect(toSecond && stops.primary == range(22, 2))
        let toEnd = stops.advance(by: 1)
        #expect(toEnd && stops.primary == range(24, 0))
        #expect(stops.isAtLast)
        let pastEnd = stops.advance(by: 1)
        #expect(!pastEnd)
    }

    @Test func typingAtTheEndOfTheCurrentStopGrowsItAndMovesTheStopRightAfterIt() {
        // "ab": stop 1 is "a", stop 2 "b" right after it.
        var stops = SnippetStops(expand("${1:a}${2:b}"), at: 0)
        let inPrimary = stops.replace(range(1, 0), newLength: 1)
        #expect(inPrimary)
        #expect(stops.primary == range(0, 2))
        let toSecond = stops.advance(by: 1)
        #expect(toSecond && stops.primary == range(2, 1))
    }

    @Test func typingOverAPlaceholderDropsTheStopsInsideItAndTabPassesThem() {
        // "a b": stop 1 is "a b" and holds stop 2, "b"; stop 3 is at the end.
        var stops = SnippetStops(expand("${1:a ${2:b}}$3"), at: 0)
        let inPrimary = stops.replace(range(0, 3), newLength: 1)
        #expect(inPrimary)
        #expect(stops.primary == range(0, 1))
        let forward = stops.advance(by: 1)
        #expect(forward && stops.primary == range(1, 0))
        #expect(!stops.isAtLast)
        let back = stops.advance(by: -1)
        #expect(back && stops.primary == range(0, 1))
    }

    @Test func anEditBeforeTheSnippetMovesEveryStopAndIsNotInTheCurrentOne() {
        // "x = x" at 10: stop 1 is the first x, mirrored by the second.
        var stops = SnippetStops(expand("${1:x} = $1"), at: 10)
        #expect(stops.primary == range(10, 1))
        #expect(stops.mirrors == [range(14, 1)])
        let inPrimary = stops.replace(range(2, 3), newLength: 0)
        #expect(!inPrimary)
        #expect(stops.primary == range(7, 1))
        #expect(stops.mirrors == [range(11, 1)])
    }

    @Test func anEditAfterTheSnippetOrInAnotherStopIsNotInTheCurrentOne() {
        // "a b": stop 1 is "a", stop 2 "b".
        var stops = SnippetStops(expand("${1:a} ${2:b}"), at: 0)
        let after = stops.replace(range(10, 0), newLength: 4)
        #expect(!after)
        #expect(stops.primary == range(0, 1))
        let inSecond = stops.replace(range(2, 1), newLength: 2)
        #expect(!inSecond)
        #expect(stops.primary == range(0, 1))
        let toSecond = stops.advance(by: 1)
        #expect(toSecond && stops.primary == range(2, 2))
    }
}
