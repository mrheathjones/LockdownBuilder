import SwiftUI

// Shared building blocks for the card-based layout. Semantic colors only, so light mode and the
// user's accent color both work.

extension View {
    /// A grouped card: radius 10, subtle fill, hairline border (tinted when the card has a problem).
    func card(border: Color? = nil, fill: Color? = nil) -> some View {
        background(fill ?? Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(border ?? Color.primary.opacity(0.08), lineWidth: border == nil ? 0.5 : 1))
    }
}

/// A rounded square with a white symbol on a tint, or a secondary symbol on a neutral fill.
struct IconTile: View {
    let symbol: String
    var tint: Color?
    var size: CGFloat = 24

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.25)
            .fill(tint.map(AnyShapeStyle.init) ?? AnyShapeStyle(.quaternary))
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.54, weight: .medium))
                    .foregroundStyle(tint == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.white))
            }
            .accessibilityHidden(true)
    }
}

/// A small capsule label such as SAFE or Presence.
struct Badge: View {
    let text: String
    var tint: Color?

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(tint.map(AnyShapeStyle.init) ?? AnyShapeStyle(.secondary))
            .background(tint.map { AnyShapeStyle($0.opacity(0.15)) } ?? AnyShapeStyle(.quaternary),
                        in: RoundedRectangle(cornerRadius: 4))
    }
}

/// "1  What to quit": the numbered header above each step of the rule builder.
struct StepHeader: View {
    let number: Int
    let title: String

    var body: some View {
        HStack(spacing: 8) {
            Text("\(number)")
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(.tint, in: Circle())
            Text(title).font(.system(size: 13, weight: .semibold))
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityLabel("Step \(number): \(title)")
    }
}

/// A friendly label with the plist key underneath (hidden when "Show plist keys" is off).
struct FieldLabel: View {
    let title: String
    var key: String?
    var subtitle: String?
    @AppStorage("showPlistKeys") private var showKeys = true

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 13, weight: .medium))
            if let subtitle {
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if let key, showKeys {
                Text(key).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.tertiary)
            }
        }
    }
}

/// A validation message under a field.
struct IssueLabel: View {
    let issue: ValidationIssue

    var body: some View {
        Label(issue.message, systemImage: issue.isError ? "xmark.circle.fill" : "exclamationmark.triangle.fill")
            .font(.system(size: 11))
            .foregroundStyle(issue.isError ? .red : .orange)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A plain button that looks like a card and brightens on hover.
struct CardButton<Label: View>: View {
    var padding = EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16)
    let action: () -> Void
    @ViewBuilder let label: Label
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            label
                .padding(padding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(RoundedRectangle(cornerRadius: 10))
                .card(fill: Color.primary.opacity(hovering ? 0.08 : 0.04))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Lays children out left to right, wrapping to the next line when the width runs out.
struct FlowLayout: Layout {
    var spacing: CGFloat = 5
    var lineSpacing: CGFloat = 5

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = arrange(width: bounds.width, subviews: subviews).frames
        for (subview, frame) in zip(subviews, frames) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        var frames: [CGRect] = []
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            var size = subview.sizeThatFits(.unspecified)
            if size.width > width { size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil)) }
            if x > 0, x + size.width > width {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return (CGSize(width: maxX, height: y + lineHeight), frames)
    }
}

extension BuiltInTemplate.Tint {
    var color: Color {
        switch self {
        case .blue: .blue
        case .indigo: .indigo
        case .orange: .orange
        case .green: .green
        case .gray: .gray
        case .red: .red
        }
    }
}

extension RuleModel.Kind {
    var label: String {
        switch self {
        case .presence: "Presence"
        case .event: "Event"
        case .watchOneKillAnother: "Watch & Kill"
        case .notifyOnly: "Notify Only"
        }
    }
}

extension RuleModel.DialogPosition {
    var label: String {
        switch self {
        case .topLeft: "Top left"
        case .top: "Top"
        case .topRight: "Top right"
        case .left: "Left"
        case .center: "Center"
        case .right: "Right"
        case .bottomLeft: "Bottom left"
        case .bottom: "Bottom"
        case .bottomRight: "Bottom right"
        }
    }
}

extension RuleModel {
    /// "Presence · App Store": the second line of a sidebar row or template card.
    func summaryLine(kind: Kind? = nil) -> String {
        let kind = kind ?? self.kind
        if kind == .notifyOnly { return "\(kind.label) · nothing is quit" }
        return "\(kind.label) · \(killProcess ?? "no process yet")"
    }
}
