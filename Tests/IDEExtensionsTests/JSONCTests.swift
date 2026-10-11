import Foundation
import IDEExtensions
import Testing

@Suite struct JSONCTests {
    @Test func commentsAndTrailingCommasGoButNotInsideStrings() throws {
        let text = #"""
        {
            // The "name": not a key.
            "url": "https://example.com/*path*/", /* a block
            comment */ "quote": "say \"hi\" // still the string",
            "slash": "\\",
            "list": [1, 2, /* three */ 3,],
            "nested": { "a": "b", },
        }
        """#
        let object = try #require(JSONC.object(from: Data(text.utf8)) as? [String: Any])
        #expect(object.count == 5)
        #expect(object["url"] as? String == "https://example.com/*path*/")
        #expect(object["quote"] as? String == #"say "hi" // still the string"#)
        #expect(object["slash"] as? String == "\\")
        #expect(object["list"] as? [Int] == [1, 2, 3])
        #expect((object["nested"] as? [String: Any])?["a"] as? String == "b")
    }

    @Test func aTabTypedIntoAStringIsKept() throws {
        let object = try #require(JSONC.object(from: Data("{ \"body\": \"a\tb\" }".utf8)) as? [String: String])
        #expect(object["body"] == "a\tb")
    }

    @Test func aCommentStillSeparatesAndWhatIsNotJSONThrows() {
        #expect(throws: (any Error).self) { try JSONC.object(from: Data("[1/**/2]".utf8)) }
        #expect(throws: (any Error).self) { try JSONC.object(from: Data(#"{ "a": 1 /* never closed }"#.utf8)) }
    }
}

@Suite struct RGBATests {
    @Test func everyHexFormInEitherCase() {
        let component = { (value: Int) in Double(value) / 255 }
        #expect(RGBA(hex: "#fFf") == RGBA(red: 1, green: 1, blue: 1))
        #expect(RGBA(hex: "#F008") == RGBA(red: 1, green: 0, blue: 0, alpha: component(0x88)))
        #expect(RGBA(hex: "#336699") == RGBA(red: component(0x33), green: component(0x66), blue: component(0x99)))
        #expect(
            RGBA(hex: "#3366997f")
                == RGBA(red: component(0x33), green: component(0x66), blue: component(0x99), alpha: component(0x7F)))
        #expect(RGBA(hex: "#ABCDEF") == RGBA(hex: "#abcdef"))
    }

    @Test func anythingElseIsNoColor() {
        let texts = ["", "#", "fff", "336699", "#ff", "#fffff", "#fffffff", "#fffffffff", "#ggg", "#+fff", "#-fff"]
        for text in texts + ["#１２３"] {
            #expect(RGBA(hex: text) == nil, "\(text)")
        }
    }
}
