import SwiftUI

/// Placeholder shell for phase 1: lists the built-in templates and previews their generated plist.
/// The real editor UI is built in the next phase.
struct ContentView: View {
    private let settings = RuleSettings()
    @State private var selection: String? = BuiltInTemplates.all.first?.id

    var body: some View {
        NavigationSplitView {
            List(BuiltInTemplates.all, selection: $selection) { template in
                Text(template.id)
            }
            .navigationTitle("Templates")
        } detail: {
            if let id = selection, let template = BuiltInTemplates.template(id: id) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(template.summary).font(.headline)
                        Text(template.notes).foregroundStyle(.secondary)
                        Text(RuleExport.plist(for: template.rule(settings: settings)))
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ContentUnavailableView("Select a template", systemImage: "doc.text")
            }
        }
    }
}

#Preview {
    ContentView()
}
