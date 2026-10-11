import Foundation
import IDEExtensions
import Testing

@Suite struct SnippetFileTests {
    @Test func prefixesAndBodiesInEitherFormAndIncompleteEntriesLeftOut() throws {
        let folder = try TempFolder()
        let url = try folder.write("snippets.code-snippets", #"""
        {
            // Comments are allowed.
            "Print": { "prefix": "log", "body": "console.log($1);", "description": "Log output" },
            "For Loop": {
                "prefix": ["for", "fori", ""],
                "body": ["for (let ${1:i} = 0; $1 < ${2:n}; $1++) {", "\t$0", "}"],
                "description": ["Loop", "with an index"],
            },
            "No prefix": { "body": "x" },
            "Empty prefix": { "prefix": "", "body": "x" },
            "Empty body": { "prefix": "e", "body": "" },
            "Group": { "Nested": { "prefix": "nest", "body": "nested" } },
        }
        """#)
        #expect(try SnippetFile.load(url) == [
            Snippet(
                name: "For Loop", prefixes: ["for", "fori"], body: "for (let ${1:i} = 0; $1 < ${2:n}; $1++) {\n\t$0\n}",
                summary: "Loop\nwith an index"),
            Snippet(name: "Nested", prefixes: ["nest"], body: "nested", summary: nil),
            Snippet(name: "Print", prefixes: ["log"], body: "console.log($1);", summary: "Log output"),
        ])
    }
}

@Suite struct SnippetExpanderTests {
    @Test func nestedPlaceholdersAreEachAStopAndTheEndIsTheLast() {
        let expansion = expand("${1:placeholder with ${2:nested}} done")
        #expect(expansion.text == "placeholder with nested done")
        #expect(expansion.tabStops == [
            .init(index: 1, ranges: [range(0, 23)]),
            .init(index: 2, ranges: [range(17, 6)]),
            .init(index: 0, ranges: [range(28, 0)]),
        ])
    }

    @Test func aStopsCopiesShowTheTextOfItsFirstPlaceholderWithText() {
        // $2 comes before the placeholder that gives it its text.
        let expansion = expand("${1:name} = $1; $2 + ${2:x}")
        #expect(expansion.text == "name = name; x + x")
        #expect(expansion.tabStops == [
            .init(index: 1, ranges: [range(0, 4), range(7, 4)]),
            .init(index: 2, ranges: [range(13, 1), range(17, 1)]),
            .init(index: 0, ranges: [range(18, 0)]),
        ])
        // A placeholder holding its own number does not repeat itself forever.
        #expect(expand("${1:a $1}").text == "a ")
        #expect(expand("${1:a ${1/(.*)/x/}}").text == "a x")
    }

    @Test func tabsAreVisitedInOrderWithAnExplicitEndLast() {
        let expansion = expand("$0 ${2:b} ${1:a}")
        #expect(expansion.text == " b a")
        #expect(expansion.tabStops.map(\.index) == [1, 2, 0])
        #expect(expansion.tabStops.last?.ranges == [range(0, 0)])
    }

    @Test func choicesInsertTheirFirstOptionAndEscapesTheCharacter() {
        let expansion = expand(#"${1|one,two|} ${2|a\,b,c|} \$1 \} \\ \x ${3:a\}b} }"#)
        #expect(expansion.text == #"one a,b $1 } \ \x a}b }"#)
        #expect(expansion.tabStops == [
            .init(index: 1, ranges: [range(0, 3)]),
            .init(index: 2, ranges: [range(4, 3)]),
            .init(index: 3, ranges: [range(18, 3)]),
            .init(index: 0, ranges: [range(23, 0)]),
        ])
        // Outside a choice, a comma or a bar is not escaped.
        #expect(expand(#"a\,b\|c"#).text == #"a\,b\|c"#)
    }

    @Test func variablesTakeTheirValueTheirDefaultOrBecomePlaceholdersNamedAfterThem() {
        let expansion = expand(
            "${TM_FILENAME} ${EMPTY:fallback} ${UNSET:default} $1 $UNKNOWN ${UNKNOWN} $EMPTY.",
            values: ["TM_FILENAME": "main.swift", "EMPTY": ""])
        #expect(expansion.text == "main.swift fallback default  UNKNOWN UNKNOWN .")
        #expect(expansion.tabStops == [
            .init(index: 1, ranges: [range(28, 0)]),
            .init(index: 2, ranges: [range(29, 7), range(37, 7)]),
            .init(index: 0, ranges: [range(46, 0)]),
        ])
    }

    @Test func linesAreIndentedAndTheirLeadingTabsBecomeTheIndentUnit() {
        let expansion = expand("if ${1:cond} {\n\t${2:body\nmore}\n}$0", indentation: "  ", indentUnit: "    ")
        #expect(expansion.text == "if cond {\n      body\n  more\n  }")
        #expect(expansion.tabStops == [
            .init(index: 1, ranges: [range(3, 4)]),
            .init(index: 2, ranges: [range(16, 11)]),
            .init(index: 0, ranges: [range(31, 0)]),
        ])
        // Only the tabs a line starts with; a value's line breaks are indented too.
        #expect(expand("\tx\ty\r\n\t\tz", indentUnit: "  ").text == "  x\ty\n    z")
        #expect(expand("{$TEXT}", indentation: "\t", values: ["TEXT": "a\nb"]).text == "{a\n\tb}")
    }

    @Test func rangesCountUTF16() {
        let expansion = expand("\u{1F600} ${1:e\u{301}}")
        #expect(expansion.tabStops.first == .init(index: 1, ranges: [range(3, 2)]))
        #expect(expansion.tabStops.last == .init(index: 0, ranges: [range(5, 0)]))
    }

    @Test func transformsRewriteAVariableOrAPlaceholdersText() {
        let values = ["BASE": "my_file", "NAME": "a_b_c", "WORDS": "my-file name", "FOO": "foo bar", "BAR": "bar"]
        let cases: [(String, String)] = [
            ("${BASE/(.*)/${1:/upcase}/}", "MY_FILE"),
            ("${NAME/_/-/g}", "a-b-c"),
            ("${NAME/_/-/}", "a-b_c"),
            ("${NAME/B/x/gi}", "a_x_c"),
            ("${FOO/^(foo)?.*$/${1:?yes:no}/}", "yes"),
            ("${BAR/^(foo)?.*$/${1:?yes:no}/}", "no"),
            ("${FOO/(\\w+) (\\w+)/$2 ${1:/capitalize}/}", "bar Foo"),
            ("${WORDS/(.*)/${1:/pascalcase}/}", "MyFileName"),
            ("${WORDS/(.*)/${1:/camelcase}/}", "myFileName"),
            ("${BAR/(x)/${1:-none}/}", "none"),
            ("${BAR/(x)/y/}", "bar"),
            ("${MISSING/^$/empty/}", "empty"),
            ("${NAME/_/\\//g}", "a/b/c"),
            ("${BAR/(/x/}", "${BAR/(/x/}"),
            ("${BAR/a/x/q}", "${BAR/a/x/q}"),
        ]
        for (body, text) in cases {
            #expect(expand(body, values: values).text == text, "\(body)")
        }
        let placeholder = expand("${1:hello} ${1/(.)(.*)/${1:/upcase}$2/}")
        #expect(placeholder.text == "hello Hello")
        #expect(placeholder.tabStops == [
            .init(index: 1, ranges: [range(0, 5)]),
            .init(index: 0, ranges: [range(11, 0)]),
        ])
    }

    @Test func whatDoesNotParseIsInsertedAsWritten() {
        let unclosed = expand("${1:abc ${2:d}")
        #expect(unclosed.text == "${1:abc d")
        #expect(unclosed.tabStops == [.init(index: 2, ranges: [range(8, 1)]), .init(index: 0, ranges: [range(9, 0)])])
        #expect(expand("$ ${ x} ${1x} ${0|a|} ${1|a,|} ${2|a|b} $").text == "$ ${ x} ${1x} ${0|a|} ${1|a,|} ${2|a|b} $")
    }
}
