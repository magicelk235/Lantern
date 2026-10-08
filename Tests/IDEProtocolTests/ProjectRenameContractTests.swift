import Foundation
@testable import IDEProtocol
import Testing

/// Rename Project… on the wire, and where a renamed folder's paths go.
@Suite struct ProjectRenameContractTests {
    @Test func paramsAndResultAreTheExactWireShape() throws {
        let params = ProjectRename.Params(from: "/Users/me/src/app", to: "/Users/me/src/web")
        #expect(
            String(decoding: try IDECoding.encoder().encode(params), as: UTF8.self)
                == #"{"from":"/Users/me/src/app","moveFolder":true,"to":"/Users/me/src/web"}"#)
        let result = ProjectRename.Result(workspace: "/Users/me/src/web", resumed: ["s1"], notMoved: ["Its memory"])
        #expect(
            String(decoding: try IDECoding.encoder().encode(result), as: UTF8.self)
                == #"{"notMoved":["Its memory"],"resumed":["s1"],"workspace":"/Users/me/src/web"}"#)
        #expect(try IDECoding.decoder().decode(ProjectRename.Result.self, from: IDECoding.encoder().encode(result)) == result)
    }

    @Test func aLocatedFolderIsNotMovedAgain() throws {
        let params = try IDECoding.decoder().decode(
            ProjectRename.Params.self, from: Data(#"{"from":"/a","to":"/b","moveFolder":false}"#.utf8))
        #expect(params == ProjectRename.Params(from: "/a", to: "/b", moveFolder: false))
        let defaulted = try IDECoding.decoder().decode(ProjectRename.Params.self, from: Data(#"{"from":"/a","to":"/b"}"#.utf8))
        #expect(defaulted.moveFolder)
    }

    @Test func pathsInTheFolderFollowItAndNoOthers() {
        let move = FolderMove(from: "/Users/me/src/app", to: "/Users/me/src/web")
        #expect(move.moved("/Users/me/src/app") == "/Users/me/src/web")
        #expect(move.moved("/Users/me/src/app/Sources/main.swift") == "/Users/me/src/web/Sources/main.swift")
        #expect(move.moved("/Users/me/src/app-cli") == nil, "a sibling sharing the name's start stays")
        #expect(move.moved("/Users/me/src") == nil)
        #expect(move.moved("app/main.swift") == nil)
        #expect(move.contains("/Users/me/src/app/x") && !move.contains("/Users/me/src/apps"))
        #expect(move.reversed.moved("/Users/me/src/web/x") == "/Users/me/src/app/x")
    }

    @Test func pathsCompareByteForByte() {
        // The same name in another Unicode normalization is another path to compare: paths come from the file system.
        let move = FolderMove(from: "/tmp/caf\u{E9}", to: "/tmp/bar")
        #expect(move.moved("/tmp/caf\u{E9}/x") == "/tmp/bar/x")
        #expect(move.moved("/tmp/cafe\u{301}/x") == nil)
        // A combining mark right after the separator still counts as inside.
        #expect(move.moved("/tmp/caf\u{E9}/\u{301}x") == "/tmp/bar/\u{301}x")
    }
}
