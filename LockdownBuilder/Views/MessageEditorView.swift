import SwiftUI

/// An entry in the message editor's `{}` insert menu.
struct MessageEditorVariable: Identifiable {
    let token: String
    let summary: String
    /// The current value, shown in the menu when not empty.
    var value = ""

    var id: String { token }

    /// The watcher's variables with the values they take for `rule`.
    static func watcher(rule: RuleModel, settings: RuleSettings) -> [MessageEditorVariable] {
        MessageVariable.allCases.map {
            MessageEditorVariable(token: $0.token, summary: $0.summary, value: $0.value(rule: rule, settings: settings))
        }
    }

    /// The footer under a rule's message.
    static var watcherFooter: String {
        "Select text, then use the buttons above. The message is stored as Markdown; blank lines make paragraphs. Variables such as {{companyName}} are filled in by the watcher (\(RuleModel.variablesAndInfoButtonMinimumWatcherVersion) or later); the preview shows their values."
    }
}

/// Title and body as separate fields over one `DialogMessage`, with a toolbar that writes the Markdown
/// for the selected text.
struct MessageEditor<Accessory: View>: View {
    @Binding var message: String
    let hasError: Bool
    /// The `{{…}}` entries of the insert menu, with their current values.
    let variables: [MessageEditorVariable]
    /// The explanation under the text, e.g. who fills the variables in.
    let footer: String
    @ViewBuilder let accessory: Accessory
    @State private var title: String
    @State private var text: String
    @State private var selection: TextSelection?

    init(message: Binding<String>, hasError: Bool, variables: [MessageEditorVariable],
         footer: String = MessageEditorVariable.watcherFooter, @ViewBuilder accessory: () -> Accessory) {
        _message = message
        self.hasError = hasError
        self.variables = variables
        self.footer = footer
        self.accessory = accessory()
        let parts = DialogMessageParts.split(message.wrappedValue)
        _title = State(initialValue: parts.title)
        _text = State(initialValue: parts.body)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                FieldLabel(title: "Title", key: "DialogMessage (# first line)")
                TextField("Title", text: $title, prompt: Text("None"))
                    .labelsHidden()
                    .font(.system(size: 14, weight: .semibold))
                    .accessibilityLabel("Dialog title")
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    FieldLabel(title: "Message", key: "DialogMessage")
                    Spacer()
                    accessory
                }
                .controlSize(.small)
                toolbar
                TextEditor(text: $text, selection: $selection)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(minHeight: 130)
                    .background(.background, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(hasError ? AnyShapeStyle(Color.red.opacity(0.5)) : AnyShapeStyle(.quaternary)))
                    .accessibilityLabel("Dialog message")
                Text(footer)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onChange(of: title) { message = DialogMessageParts.join(title: title, body: text) }
        .onChange(of: text) { message = DialogMessageParts.join(title: title, body: text) }
        .onChange(of: message) {
            // A preset or an AI draft replaced the message from outside: show its parts.
            guard DialogMessageParts.join(title: title, body: text) != message else { return }
            (title, text) = DialogMessageParts.split(message)
            selection = nil
        }
    }

    private var toolbar: some View {
        HStack(spacing: 2) {
            style("Bold", "bold", shortcut: "b") { MarkdownStyling.toggleInline("**", in: $0, range: $1) }
            style("Italic", "italic", shortcut: "i") { MarkdownStyling.toggleInline("_", in: $0, range: $1) }
            style("Strikethrough", "strikethrough") { MarkdownStyling.toggleInline("~~", in: $0, range: $1) }
            style("Code", "chevron.left.forwardslash.chevron.right") { MarkdownStyling.toggleInline("`", in: $0, range: $1) }
            Divider().frame(height: 14).padding(.horizontal, 4)
            style("Heading", "textformat.size") { MarkdownStyling.toggleLinePrefix("## ", in: $0, range: $1) }
            style("Bulleted list", "list.bullet") { MarkdownStyling.toggleLinePrefix("- ", in: $0, range: $1) }
            style("Link", "link") { MarkdownStyling.link(in: $0, range: $1) }
            Divider().frame(height: 14).padding(.horizontal, 4)
            Menu {
                ForEach(variables) { entry in
                    Button("\(entry.token) — \(entry.summary)\(entry.value.isEmpty ? "" : " (\(entry.value))")") {
                        apply { MarkdownStyling.insert(entry.token, in: $0, range: $1) }
                    }
                }
            } label: {
                // The label goes on the image: a Menu reports its label view's name, not its own.
                Image(systemName: "curlybraces").frame(width: 24, height: 20).contentShape(Rectangle())
                    .accessibilityLabel("Insert variable")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Insert a {{…}} variable")
            Spacer()
        }
        .buttonStyle(.borderless)
    }

    /// Runs a Markdown edit on the selection (or at the end of the text when nothing is selected).
    private func apply(_ edit: (String, Range<String.Index>) -> MarkdownStyling.Edit) {
        var range = text.endIndex..<text.endIndex
        if case .selection(let selected) = selection?.indices, selected.upperBound <= text.endIndex {
            range = selected
        }
        let result = edit(text, range)
        text = result.text
        selection = TextSelection(range: result.selection)
    }

    private func style(_ name: String, _ symbol: String, shortcut: KeyEquivalent? = nil,
                       _ edit: @escaping (String, Range<String.Index>) -> MarkdownStyling.Edit) -> some View {
        Button {
            apply(edit)
        } label: {
            Image(systemName: symbol).frame(width: 24, height: 20).contentShape(Rectangle())
        }
        .keyboardShortcut(shortcut.map { KeyboardShortcut($0) })
        .help(shortcut.map { "\(name) (⌘\(String($0.character).uppercased()))" } ?? name)
        .accessibilityLabel(name)
    }
}

