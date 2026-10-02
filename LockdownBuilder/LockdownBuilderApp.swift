import SwiftUI

@main
struct LockdownBuilderApp: App {
    @State private var store = ProjectStore()

    var body: some Scene {
        WindowGroup {
            ContentView(store: store)
                .environment(\.ruleAssistant, RuleAssistants.make(enabled: store.settings.aiEnabled))
        }
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Rule") { store.newRule() }
                    .keyboardShortcut("n")
                Button("Open Folder…") { store.openFolder() }
                    .keyboardShortcut("o")
                Button("Import Plist…") { store.importPlists() }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save") { store.save() }
                    .keyboardShortcut("s")
            }
            CommandMenu("Rule") {
                Button("Test Rule…") {
                    if case .rule = store.selection { store.isShowingTestHarness = true }
                    else { store.message = "Select a rule to test." }
                }
                .keyboardShortcut("t")
            }
            CommandMenu("Export") {
                Button("Export Selected Plist…") { exportSelected(.plist) }
                    .keyboardShortcut("e")
                Button("Export Selected .mobileconfig…") { exportSelected(.mobileconfig) }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                Divider()
                Button("Export All Plists…") { store.exportAll(format: .plist) }
                Button("Export All .mobileconfig…") { store.exportAll(format: .mobileconfig) }
                Button("Export JSON Schema…") { store.exportSchema() }
            }
        }
        Settings {
            SettingsView(store: store)
                .environment(\.ruleAssistant, RuleAssistants.make(enabled: store.settings.aiEnabled))
        }
    }

    private func exportSelected(_ format: ExportFormat) {
        guard case .rule(let id) = store.selection, let draft = store.draft(id: id) else {
            store.message = "Select a rule to export."
            return
        }
        store.export(draft, format: format)
    }
}
