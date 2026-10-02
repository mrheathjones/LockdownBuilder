import SwiftUI

/// Read-only view of a built-in template with "Duplicate to edit".
struct TemplateDetailView: View {
    let store: ProjectStore
    let template: BuiltInTemplate

    var body: some View {
        let rule = template.rule(settings: store.settings)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading) {
                        Text(template.id).font(.title2.bold())
                        Text(template.summary).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Duplicate to Edit", systemImage: "plus.square.on.square") {
                        store.duplicateTemplate(id: template.id)
                    }
                    .buttonStyle(.borderedProminent)
                }
                GroupBox("Why this works / caveats") {
                    Text(template.notes)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(4)
                }
                GroupBox("Generated plist") {
                    Text(RuleExport.plist(for: rule))
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(4)
                }
            }
            .padding()
        }
        .navigationTitle("Template: \(template.id)")
    }
}
