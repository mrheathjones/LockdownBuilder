import SwiftUI

/// Line diff between the last exported plist and what the rule would export now.
struct DiffView: View {
    let ruleName: String
    let old: String?
    let new: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("“\(ruleName)” compared with its last export").font(.headline)
            if let old {
                let lines = LineDiff.diff(old: old, new: new)
                if LineDiff.hasChanges(lines) {
                    ScrollView([.vertical, .horizontal]) {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                                row(line)
                            }
                        }
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                    }
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
                } else {
                    ContentUnavailableView("No Changes", systemImage: "checkmark.circle",
                                           description: Text("The rule exports exactly what was exported last time."))
                }
            } else {
                ContentUnavailableView("Never Exported", systemImage: "clock",
                                       description: Text("Export this rule's plist once to compare later versions with it."))
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 680, height: 520)
    }

    @ViewBuilder
    private func row(_ line: LineDiff.Line) -> some View {
        switch line {
        case .same(let text):
            Text("  " + text)
        case .removed(let text):
            Text("− " + text)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.red.opacity(0.12))
                .accessibilityLabel("Removed: \(text)")
        case .added(let text):
            Text("+ " + text)
                .foregroundStyle(.green)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.green.opacity(0.12))
                .accessibilityLabel("Added: \(text)")
        }
    }
}
