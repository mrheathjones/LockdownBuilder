import SwiftUI
import UniformTypeIdentifiers

/// Finds the exact process name for KillProcess / WatchProcess.
struct TargetPickerView: View {
    let apply: (TargetChoice) -> Void
    @State private var model = TargetPickerModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Picker("Source", selection: $model.tab) {
                ForEach(TargetPickerModel.Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding()

            Group {
                switch model.tab {
                case .running: list(model.filtered(model.running), emptyText: "Loading processes…")
                case .extensions: list(model.filtered(model.extensions), emptyText: "Loading extensions…")
                case .app: appTab
                case .path: pathTab
                }
            }
            .frame(maxHeight: .infinity)

            Divider()
            selectionPanel
                .padding()
        }
        .frame(width: 680, height: 600)
        .task { await model.load() }
    }

    // MARK: Tabs

    private func list(_ targets: [ProcessTarget], emptyText: String) -> some View {
        VStack(spacing: 8) {
            TextField("Search name, bundle ID or path", text: $model.search)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)
            List(targets, selection: Binding(get: { model.selected?.id }, set: { id in
                model.select(targets.first { $0.id == id })
            })) { target in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(target.name).fontWeight(.medium)
                        Text(target.kind.rawValue).font(.caption).foregroundStyle(.secondary)
                    }
                    if let detail = target.bundleID ?? target.path {
                        Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
                .tag(target.id)
            }
            .overlay {
                if targets.isEmpty {
                    Text(model.search.isEmpty ? emptyText : "No matches").foregroundStyle(.secondary)
                }
            }
        }
    }

    private var appTab: some View {
        VStack(spacing: 16) {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [6]))
                .foregroundStyle(.secondary)
                .overlay {
                    VStack(spacing: 8) {
                        Image(systemName: "app.dashed").font(.largeTitle)
                        Text("Drop an .app or .appex here")
                        Text("The process name is the bundle's CFBundleExecutable.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(height: 180)
                .dropDestination(for: URL.self) { urls, _ in
                    guard let url = urls.first else { return false }
                    model.resolveBundle(url)
                    return true
                }
                .accessibilityLabel("Drop an app here")
            Button("Choose App…") { model.chooseApp() }
        }
        .padding()
    }

    private var pathTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Path to a command-line tool, e.g. /usr/bin/fm. The process name is the file name as invoked.")
                .foregroundStyle(.secondary)
            HStack {
                TextField("/usr/bin/fm", text: $model.pathText)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .onSubmit { model.resolvePath() }
                Button("Resolve") { model.resolvePath() }
            }
            Spacer()
        }
        .padding()
    }

    // MARK: Selection

    @ViewBuilder
    private var selectionPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let message = model.message {
                Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            if let target = model.selected {
                HStack(alignment: .firstTextBaseline) {
                    Text(target.name).font(.title3.bold()).textSelection(.enabled)
                    Text(target.kind.rawValue).foregroundStyle(.secondary)
                    Spacer()
                    pgrepStatus(target)
                }
                if model.denylisted {
                    Label("“\(target.name)” is on the safety denylist and can never be killed.", systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                }
                ForEach(target.notes, id: \.self) { note in
                    Label(note, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Cancel") { dismiss() }
                    Spacer()
                    if target.kind == .appExtension {
                        Button("Watch It, Kill System Settings") {
                            finish(.watchAndKill(watch: target.name, kill: "System Settings"))
                        }
                        .help("Recommended for System Settings extensions")
                    }
                    Button("Use as WatchProcess") { finish(.watch(target.name)) }
                    Button("Use as KillProcess") { finish(.kill(target.name)) }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.denylisted)
                }
            } else {
                HStack {
                    Text("Select a process, drop an app, or enter a path.").foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func pgrepStatus(_ target: ProcessTarget) -> some View {
        if let count = model.matchCount {
            if count > 0 {
                Label("\(count) running now (pgrep -x)", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Label("Nothing named exactly this is running now", systemImage: "exclamationmark.circle")
                    .foregroundStyle(.orange)
                    .help("Fine if the app isn't open; otherwise double-check the name.")
            }
        } else {
            ProgressView().controlSize(.small)
        }
    }

    private func finish(_ choice: TargetChoice) {
        apply(choice)
        dismiss()
    }
}

/// Inline "is it running?" check under a process-name field, debounced while typing.
struct ProcessStatusLabel: View {
    let name: String
    @State private var count: Int?

    var body: some View {
        // Always renders something: modifiers on an empty view (and so `.task`) would never run.
        HStack {
            if let count {
                if count > 0 {
                    Label("\(count) process\(count == 1 ? "" : "es") named exactly this running now", systemImage: "circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Label("Nothing named exactly this is running now (pgrep -x)", systemImage: "circle")
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Checking pgrep -x…").foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .task(id: name) {
            count = nil
            guard !name.isEmpty, !name.contains("/") else { return }
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            count = try? await ProcessRunner.shared.pgrep(name).count
        }
    }
}
