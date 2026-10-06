import AppKit
import SwiftUI

/// The editor's find bar (`EditorFind`), above the text, after Xcode's: Find or Replace, the field, how many matches
/// and which one is selected, the options, previous and next, Done; in Replace, a second row with the replacement,
/// Replace and Replace All. Return finds the next match, ⇧Return the previous one, Esc closes the bar.
struct FindBar: View {
    @Bindable var find: EditorFind

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
            GridRow {
                Picker("Mode", selection: Binding(get: { find.mode }, set: { find.setMode($0) })) {
                    Text("Find").tag(EditorFind.Mode.find)
                    Text("Replace").tag(EditorFind.Mode.replace)
                }
                .labelsHidden()
                .fixedSize()
                FindField(
                    placeholder: "Find", text: Binding(get: { find.query }, set: { find.setQuery($0) }),
                    takesFocus: find.pendingFocus == .query, focusTaken: find.focusTaken, cancel: find.hide
                ) { backwards in
                    if backwards { find.previous() } else { find.next() }
                }
                HStack(spacing: 8) {
                    Text(status)
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(minWidth: 72, alignment: .trailing)
                    options
                    ControlGroup {
                        Button { find.previous() } label: { Image(systemName: "chevron.left") }
                            .help("Find Previous (⇧⌘G)")
                        Button { find.next() } label: { Image(systemName: "chevron.right") }
                            .help("Find Next (⌘G)")
                    }
                    .fixedSize()
                    .disabled(find.matches.isEmpty)
                    Button("Done") { find.hide() }
                }
            }
            if find.mode == .replace {
                GridRow {
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    FindField(
                        placeholder: "Replace", text: $find.replacement,
                        takesFocus: find.pendingFocus == .replacement, focusTaken: find.focusTaken, cancel: find.hide
                    ) { _ in
                        find.replace()
                    }
                    HStack(spacing: 8) {
                        Button("Replace") { find.replace() }
                        Button("Replace All") { find.replaceAll() }
                    }
                    .disabled(find.matches.isEmpty)
                }
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Chrome.surface)
        .overlay(alignment: .bottom) { Divider() }
        .onExitCommand { find.hide() }
    }

    /// How the query, as typed, fares in the text.
    private var status: String {
        if find.query.isEmpty { return "" }
        if find.isInvalid { return "Invalid pattern" }
        switch find.matches.count {
        case 0: return "No matches"
        case let count:
            if let current = find.current { return "\((current + 1).formatted()) of \(count.formatted())" }
            return count == 1 ? "1 match" : "\(count.formatted()) matches"
        }
    }

    /// Case, how the query matches, and wrapping, after the menu of Xcode's find field.
    private var options: some View {
        Menu {
            Picker("Case", selection: Binding(get: { find.matchesCase }, set: { find.setMatchesCase($0) })) {
                Text("Ignoring Case").tag(false)
                Text("Matching Case").tag(true)
            }
            .pickerStyle(.inline)
            .labelsHidden()
            Picker("Matching", selection: Binding(get: { find.matching }, set: { find.setMatching($0) })) {
                ForEach(EditorFind.Matching.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            Divider()
            Toggle("Wrap Around", isOn: $find.wrapsAround)
        } label: {
            Image(systemName: "magnifyingglass")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Find Options")
    }
}

/// A field of the find bar: AppKit's own, so that ⌘F gives it the keyboard with what it holds selected the moment
/// the bar asks (`EditorFind.pendingFocus`), whatever had the focus, as every Mac find field does. Return submits (⇧Return
/// backwards), Esc closes the bar.
private struct FindField: NSViewRepresentable {
    let placeholder: String
    @Binding var text: String
    /// The bar asks for the keyboard to come here.
    let takesFocus: Bool
    let focusTaken: () -> Void
    let cancel: () -> Void
    let submit: (_ backwards: Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.placeholderString = placeholder
        field.bezelStyle = .roundedBezel
        field.controlSize = .small
        field.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.field = self
        if field.stringValue != text { field.stringValue = text }
        guard takesFocus else { return }
        // Once the field is in the window: it may have just been made for the bar that opens.
        DispatchQueue.main.async {
            guard let window = field.window else { return }
            focusTaken()
            window.makeFirstResponder(field)
            field.currentEditor()?.selectAll(nil)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView field: NSTextField, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 200, height: field.intrinsicContentSize.height)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var field: FindField

        init(_ field: FindField) {
            self.field = field
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let control = notification.object as? NSTextField else { return }
            field.text = control.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertLineBreak(_:)),
                 #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                field.submit(NSApp.currentEvent?.modifierFlags.contains(.shift) == true)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                field.cancel()
                return true
            default:
                return false
            }
        }
    }
}
