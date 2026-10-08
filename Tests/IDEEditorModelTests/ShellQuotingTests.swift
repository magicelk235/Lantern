import Foundation
import IDEEditorModel
import Testing

@Suite struct ShellQuotingTests {
    @Test func plainPathsStayAsTheyAre() {
        #expect(ShellQuoting.quote("/Users/me/Sources/main.swift") == "/Users/me/Sources/main.swift")
        #expect(ShellQuoting.quote("/tmp/v1.2_final-copy+x,y:z@host") == "/tmp/v1.2_final-copy+x,y:z@host")
        #expect(ShellQuoting.quote("/tmp/מסמך/résumé 日本.txt") == "/tmp/מסמך/résumé\\ 日本.txt")
    }

    @Test func spacesQuotesAndShellCharactersGetABackslash() {
        #expect(ShellQuoting.quote("/tmp/a b/it's (1).txt") == "/tmp/a\\ b/it\\'s\\ \\(1\\).txt")
        #expect(ShellQuoting.quote("/x/*?[a]{b}") == "/x/\\*\\?\\[a\\]\\{b\\}")
        #expect(ShellQuoting.quote("/x/$HOME`~!#^&;|<>\"=%\\") == "/x/\\$HOME\\`\\~\\!\\#\\^\\&\\;\\|\\<\\>\\\"\\=\\%\\\\")
    }

    @Test func lineBreaksAreSingleQuoted() {
        #expect(ShellQuoting.quote("/tmp/a\nb") == "/tmp/a'\n'b")
        #expect(ShellQuoting.quote("/tmp/a\tb") == "/tmp/a\\\tb")
    }

    @Test func aDropTypesEachPathFollowedByASpace() {
        #expect(ShellQuoting.dropText(["/a b", "/c"]) == "/a\\ b /c ")
        #expect(ShellQuoting.dropText([]) == "")
    }

    /// Every shell on the Mac reads each quoted path back as the path itself.
    @Test(arguments: ["/bin/sh", "/bin/bash", "/bin/zsh"])
    func shellsReadThePathBack(shell: String) throws {
        let paths = [
            "/tmp/a b/it's (1).txt", "/x/*?[a]{b}", "/x/$HOME`~!#^&;|<>\"=%\\", "/tmp/a\nb", "/tmp/a\tb", "/tmp/מסמך/résumé 日本.txt",
            "/tmp/~user/a~b^c#d", "/tmp/-rf *",
        ]
        for path in paths {
            let process = Process()
            process.executableURL = URL(filePath: shell)
            // zsh's extended globbing makes ~, ^ and # glob characters; the escapes hold there too.
            let setup = shell.hasSuffix("zsh") ? "setopt extendedglob; " : ""
            process.arguments = ["-c", setup + "printf '%s' " + ShellQuoting.quote(path)]
            let output = Pipe()
            process.standardOutput = output
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            #expect(String(decoding: data, as: UTF8.self) == path, "\(shell) read \(ShellQuoting.quote(path))")
        }
    }
}
