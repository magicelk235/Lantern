@testable import IDEModel
import Testing

@Suite struct SessionTitleTests {
    @Test func ompsTitleWinsOverThePromptAndTheWindowTitle() {
        let title = SessionTitle.resolve(title: "Fix login", prompt: "the login button does nothing", windowTitle: "π > Fix login", folder: "web")
        #expect(title == "Fix login")
    }

    @Test func anUntitledSessionGoesByItsFirstPrompt() {
        let title = SessionTitle.resolve(title: nil, prompt: "the login button does nothing", windowTitle: "π > web", folder: "web")
        #expect(title == "the login button does nothing")
    }

    @Test func beforeItsFirstPromptIsOnDiskTheTUIsWindowTitleNamesIt() {
        #expect(SessionTitle.resolve(title: nil, prompt: nil, windowTitle: "π >  Refactor the parser ", folder: "web") == "Refactor the parser")
        #expect(SessionTitle.resolve(title: "", prompt: "", windowTitle: "vim notes.md", folder: "web") == "vim notes.md")
    }

    @Test func aWindowTitleNamingOnlyTheFolderSaysNothing() {
        #expect(SessionTitle.resolve(title: nil, prompt: nil, windowTitle: "π > web", folder: "web") == "New session")
        #expect(SessionTitle.resolve(title: nil, prompt: nil, windowTitle: "π >", folder: "web") == "New session")
    }

    @Test func aSessionNobodyTypedIntoIsANewSession() {
        #expect(SessionTitle.resolve(title: nil, prompt: nil, windowTitle: nil, folder: nil) == SessionTitle.untitled)
    }
}
