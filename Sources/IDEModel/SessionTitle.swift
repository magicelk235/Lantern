/// What Lantern calls a session wherever it names one (its tab, the Agents pane, the Projects pane, notifications, close
/// confirmations): omp's title for it; else the first line of the first prompt typed into it, from its session file;
/// else what its TUI titles its window, without omp's `π >` mark and only when that says more than the folder's name;
/// else "New session", which only a session nobody has typed into yet is called.
public enum SessionTitle {
    public static let untitled = "New session"

    /// `prompt`: the first prompt's first line (`SessionFileInfo.promptTitle`). `windowTitle`: the title omp's TUI gave
    /// its terminal. `folder`: the name of the folder the session runs in.
    public static func resolve(title: String?, prompt: String?, windowTitle: String?, folder: String?) -> String {
        if let title, !title.isEmpty { return title }
        if let prompt, !prompt.isEmpty { return prompt }
        if var window = windowTitle?.trimmingCharacters(in: .whitespaces) {
            if window.hasPrefix("π >") { window = String(window.dropFirst(3)).trimmingCharacters(in: .whitespaces) }
            if !window.isEmpty, window != folder { return window }
        }
        return untitled
    }
}
