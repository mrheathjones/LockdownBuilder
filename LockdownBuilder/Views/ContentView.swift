import SwiftUI

struct ContentView: View {
    @Bindable var store: ProjectStore

    var body: some View {
        NavigationSplitView {
            SidebarView(store: store)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        } detail: {
            switch store.selection {
            case .rule(let id):
                if let index = store.drafts.firstIndex(where: { $0.id == id }) {
                    RuleEditorView(store: store, draft: $store.drafts[index])
                        .id(id)
                } else {
                    placeholder
                }
            case .template(let id):
                if let template = BuiltInTemplates.template(id: id) {
                    TemplateDetailView(store: store, template: template)
                } else {
                    placeholder
                }
            case nil:
                placeholder
            }
        }
        .alert("LockdownBuilder", isPresented: Binding(get: { store.message != nil }, set: { if !$0 { store.message = nil } })) {
            Button("OK") { store.message = nil }
        } message: {
            Text(store.message ?? "")
        }
        .frame(minWidth: 760, minHeight: 560)
    }

    private var placeholder: some View {
        ContentUnavailableView {
            Label("No Rule Selected", systemImage: "doc.badge.gearshape")
        } description: {
            Text("Create a rule, open a folder of rule plists, or start from a built-in template.")
        } actions: {
            Button("New Rule") { store.newRule() }
        }
    }
}

struct SidebarView: View {
    @Bindable var store: ProjectStore

    var body: some View {
        List(selection: $store.selection) {
            Section("Rules") {
                if store.drafts.isEmpty {
                    Text("No rules yet").foregroundStyle(.secondary)
                }
                ForEach(store.drafts) { draft in
                    RuleRow(store: store, draft: draft)
                        .tag(SidebarItem.rule(draft.id))
                        .contextMenu {
                            Button("Delete", role: .destructive) { store.delete(id: draft.id) }
                        }
                }
            }
            Section("Built-in Templates") {
                ForEach(BuiltInTemplates.all) { template in
                    Label(template.id, systemImage: "doc.text")
                        .tag(SidebarItem.template(template.id))
                }
            }
        }
        .navigationTitle(store.folderURL?.lastPathComponent ?? "LockdownBuilder")
        .toolbar {
            ToolbarItem {
                Button("New Rule", systemImage: "plus") { store.newRule() }
                    .help("New rule (⌘N)")
            }
        }
    }
}

private struct RuleRow: View {
    let store: ProjectStore
    let draft: RuleDraft

    var body: some View {
        HStack {
            Text(draft.rule.name.isEmpty ? "(unnamed)" : draft.rule.name)
                .lineLimit(1)
            Spacer()
            if store.hasErrors(draft) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .accessibilityLabel("Has errors")
            } else if store.isDirty(draft) {
                Image(systemName: "circle.fill")
                    .font(.system(size: 6))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Unsaved changes")
            }
        }
    }
}
