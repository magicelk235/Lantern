import IDEProtocol
@testable import IDEModel
import Testing

@Suite struct PTYInfoTests {
    private func info(cwd: String = "/w/app", _ command: [String]) -> PTYInfo {
        PTYInfo(ptyId: "p1", cwd: cwd, command: command, cols: 80, rows: 24, pid: 1, running: true)
    }

    @Test func aTerminalInTheProjectsOwnFolderIsTitledByItsProgramAlone() {
        #expect(info(["/bin/zsh", "-l"]).displayTitle(in: "/w/app") == "zsh")
        #expect(info(cwd: "/w/app/docs", ["/bin/zsh", "-l"]).displayTitle(in: "/w/app") == "docs — zsh")
        #expect(info(["/bin/zsh", "-l"]).displayTitle(in: nil) == "app — zsh")
    }

    @Test func ompIsFoundRunDirectlyOrThroughTheLoginShell() {
        #expect(info(["/opt/homebrew/bin/omp", "render", "/s/A.jsonl"]).ompArguments == ["render", "/s/A.jsonl"])
        let script = "'omp' 'ps' 'logs' 'web' '--follow' '--dir' '/w/it'\\''s'"
        #expect(info(["/bin/zsh", "-l", "-c", script]).ompArguments == ["ps", "logs", "web", "--follow", "--dir", "/w/it's"])
        #expect(info(["/bin/zsh", "-l"]).ompArguments == nil)
        #expect(info(["/bin/zsh", "-l", "-c", "omp render x; rm -rf y"]).ompArguments == nil)
        #expect(info(["/bin/zsh", "-l", "-c", "'vim' 'x'"]).ompArguments == nil)
    }
}
