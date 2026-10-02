import AppKit
import SwiftUI

struct ContentView: View {
    @Bindable var store: ProjectStore

    var body: some View {
        NavigationSplitView {
            SidebarView(store: store)
                .navigationSplitViewColumnWidth(min: 200, ideal: 260, max: 320)
        } detail: {
            switch store.selection {
            case .rule(let id):
                if let index = store.drafts.firstIndex(where: { $0.id == id }) {
                    RuleEditorView(store: store, draft: $store.drafts[index])
                        .id(id)
                } else {
                    StartView(store: store)
                }
            case .template(let id):
                if let template = BuiltInTemplates.template(id: id) {
                    TemplateDetailView(store: store, template: template)
                } else {
                    StartView(store: store)
                }
            case .settings:
                SettingsView(store: store, embedded: true)
            case .home, nil:
                StartView(store: store)
            }
        }
        .alert("LockdownBuilder", isPresented: Binding(get: { store.message != nil }, set: { if !$0 { store.message = nil } })) {
            Button("OK") { store.message = nil }
        } message: {
            Text(store.message ?? "")
        }
        .frame(minWidth: 760, minHeight: 560)
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @Bindable var store: ProjectStore
    @AppStorage("templatesExpanded") private var templatesExpanded = true

    var body: some View {
        List(selection: $store.selection) {
            Label("Home", systemImage: "house")
                .font(.system(size: 13, weight: .medium))
                .padding(.vertical, 2)
                .tag(SidebarItem.home)
            Section("Rules") {
                if store.drafts.isEmpty {
                    Button { store.newRule() } label: {
                        Label("New Rule", systemImage: "plus")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                            .overlay(RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(.tertiary, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                    }
                    .buttonStyle(.plain)
                    .help("New rule (⌘N)")
                }
                ForEach(store.drafts) { draft in
                    RuleRow(store: store, draft: draft)
                        .tag(SidebarItem.rule(draft.id))
                        .contextMenu {
                            Button("Delete", role: .destructive) { store.delete(id: draft.id) }
                        }
                }
            }
            Section("Built-in Templates", isExpanded: $templatesExpanded) {
                ForEach(BuiltInTemplates.all) { template in
                    SidebarRow(
                        symbol: template.symbol, tint: template.tint.color, title: template.id,
                        subtitle: template.rule(settings: store.settings).summaryLine())
                        .tag(SidebarItem.template(template.id))
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        .navigationTitle(store.folderURL?.lastPathComponent ?? "LockdownBuilder")
        .toolbar {
            ToolbarItem {
                Button("New Rule", systemImage: "plus") { store.newRule() }
                    .help("New rule (⌘N)")
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            // Pinned below the list so it stays put when the sections scroll or collapse.
            Button { store.selection = .settings } label: {
                Label("Settings", systemImage: "gearshape")
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(RoundedRectangle(cornerRadius: 6))
                    .background(store.selection == .settings ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
                                in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8)
            .padding(.top, 6)
            .help("Company name, dialog branding and Jamf Pro (⌘,)")
            .accessibilityAddTraits(store.selection == .settings ? [.isSelected] : [])
            HStack(spacing: 6) {
                Image(systemName: "folder").foregroundStyle(.secondary)
                Text(store.folderURL?.lastPathComponent ?? "No folder open")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(store.folderURL?.path ?? "Rules are kept between launches; Save (⌘S) writes them to a folder of plists")
                Spacer(minLength: 4)
                Button("Open…") { store.openFolder() }
                    .buttonStyle(.link)
                    .help("Open a folder of rule plists (⌘O)")
            }
            .font(.system(size: 11))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
    }
}

private struct SidebarRow: View {
    let symbol: String
    var tint: Color?
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 8) {
            IconTile(symbol: symbol, tint: tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct RuleRow: View {
    let store: ProjectStore
    let draft: RuleDraft

    var body: some View {
        HStack {
            SidebarRow(
                symbol: "shield.checkered", title: draft.rule.name.isEmpty ? "(unnamed)" : draft.rule.name,
                subtitle: draft.rule.summaryLine(kind: draft.mode))
            Spacer(minLength: 4)
            if store.hasErrors(draft) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Has errors")
            }
            if store.isDirty(draft) {
                Image(systemName: "circle.fill")
                    .font(.system(size: 6))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Unsaved changes")
            }
        }
    }
}

// MARK: - Start screen

/// Shown when nothing is selected: what the app does, the three ways to begin, and the templates.
private struct StartView: View {
    let store: ProjectStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 36) {
                HStack(spacing: 20) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 88, height: 88)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Build a lockdown rule").font(.system(size: 24, weight: .semibold))
                        Text("Each rule tells the Restricted Item Watcher what to quit, when to act, and what to tell the user.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: 380, alignment: .leading)
                    }
                }

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                    action("New Rule", "Start from a blank rule", "⌘N", symbol: "plus.circle.fill", tint: .accentColor) {
                        store.newRule()
                    }
                    action("Open Folder…", "Edit existing rule plists", "⌘O", symbol: "folder.fill", tint: .cyan) {
                        store.openFolder()
                    }
                    action("Import…", "Validate a rule .plist", "⇧⌘I", symbol: "square.and.arrow.down.fill", tint: .purple) {
                        store.importPlists()
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Start from a template").font(.system(size: 13, weight: .semibold))
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 2), spacing: 8) {
                        ForEach(BuiltInTemplates.all) { template in
                            CardButton(padding: EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12)) {
                                store.selection = .template(template.id)
                            } label: {
                                HStack(spacing: 10) {
                                    IconTile(symbol: template.symbol, tint: template.tint.color, size: 32)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(template.id).fontWeight(.medium)
                                        Text(template.summary)
                                            .font(.system(size: 11)).foregroundStyle(.secondary)
                                            .lineLimit(1).truncationMode(.tail)
                                    }
                                    Spacer(minLength: 4)
                                    Badge(text: template.rule(settings: store.settings).kind.label)
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(.horizontal, 40)
            .padding(.vertical, 64)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("LockdownBuilder")
    }

    private func action(
        _ title: String, _ subtitle: String, _ shortcut: String, symbol: String, tint: Color,
        perform: @escaping () -> Void
    ) -> some View {
        CardButton(action: perform) {
            VStack(alignment: .leading, spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 24))
                    .foregroundStyle(tint)
                    .frame(height: 28)  // symbols differ in height; a fixed box keeps the three cards level
                    .padding(.bottom, 4)
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                Text(shortcut).font(.system(size: 11)).foregroundStyle(.tertiary)
            }
        }
    }
}
