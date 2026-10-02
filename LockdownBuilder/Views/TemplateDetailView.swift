import SwiftUI

/// Read-only view of a built-in template with "Duplicate to edit".
struct TemplateDetailView: View {
    let store: ProjectStore
    let template: BuiltInTemplate

    var body: some View {
        let rule = template.rule(settings: store.settings)
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 14) {
                    IconTile(symbol: template.symbol, tint: template.tint.color, size: 56)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(template.id).font(.system(size: 22, weight: .semibold))
                        Text(template.summary).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Duplicate to Edit", systemImage: "plus.square.on.square") {
                        store.duplicateTemplate(id: template.id)
                    }
                    .buttonStyle(.borderedProminent)
                }

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "info.circle").foregroundStyle(.secondary)
                    Text(template.notes).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()

                VStack(spacing: 0) {
                    row("Process to quit", key: rule.killProcess == nil ? nil : "KillProcess") {
                        Text(rule.killProcess ?? "None (notify only: the dialog is shown and nothing is quit)")
                    }
                    if let watch = rule.watchProcess {
                        Divider()
                        row("Process to watch", key: "WatchProcess") { Text(watch) }
                    }
                    Divider()
                    row("When to act", key: rule.predicate == nil ? nil : "Predicate") {
                        if let predicate = rule.predicate {
                            Text(predicate).font(.system(size: 12, design: .monospaced))
                        } else {
                            Text("Presence (polled every 0.5 s)")
                        }
                    }
                    if let cooldown = rule.cooldownSeconds {
                        Divider()
                        row("Cooldown", key: "CooldownSeconds") { Text("\(cooldown) s") }
                    }
                    Divider()
                    row("Message", key: "DialogMessage") { Text(rule.dialogMessage) }
                    if rule.buttonText != nil || rule.dismissButtonText != nil {
                        Divider()
                        row("Buttons", key: "ButtonText") {
                            Text([rule.buttonText ?? "OK", rule.dismissButtonText].compactMap(\.self).joined(separator: "  ·  "))
                        }
                    }
                    if let action = rule.buttonAction {
                        Divider()
                        row("Main button opens", key: "ButtonAction") { Text(action) }
                    }
                    if let info = rule.infoButtonAction {
                        Divider()
                        row("“\(rule.infoButtonText ?? RuleModel.defaultInfoButtonText)” opens", key: "InfoButtonAction") { Text(info) }
                    }
                    if let version = rule.requiredWatcherVersion {
                        Divider()
                        row("Needs watcher", key: nil) { Text("\(version) or later") }
                    }
                }
                .card()
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(40)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Template: \(template.id)")
    }

    private func row(_ title: String, key: String?, @ViewBuilder value: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            FieldLabel(title: title, key: key)
                .frame(width: 170, alignment: .leading)
            value()
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}
