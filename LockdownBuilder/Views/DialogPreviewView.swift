import AppKit
import SwiftUI

/// An approximation of how swiftDialog renders the watcher's dialog: banner (or org title), Markdown message,
/// and one or two buttons. "Simulate dialog" in the test harness shows the real thing.
struct DialogPreviewView: View {
    let rule: RuleModel
    let settings: RuleSettings

    var body: some View {
        let document = DialogMarkdown.parse(rule.dialogMessage)
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let title = document.title {
                        Text(title).font(.title.bold())
                    }
                    ForEach(Array(document.blocks.enumerated()), id: \.offset) { _, block in
                        blockView(block)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 8) {
                Spacer()
                if let dismiss = rule.dismissButtonText {
                    fakeButton(dismiss, prominent: false)
                }
                fakeButton(rule.buttonText ?? "OK", prominent: true)
            }
            .padding(16)
        }
        .frame(minHeight: 340)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
        .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Dialog preview")
    }

    @ViewBuilder
    private var header: some View {
        if settings.bannerImagePath.isEmpty {
            // Without a banner the watcher passes --title "<org>".
            Text(settings.orgNameFriendly)
                .font(.title2.bold())
                .frame(maxWidth: .infinity)
                .padding(.top, 18)
                .padding(.bottom, 4)
        } else if let image = NSImage(contentsOfFile: settings.bannerImagePath) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(height: 110)
                .frame(maxWidth: .infinity)
                .clipped()
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 12, topTrailingRadius: 12))
        } else {
            ZStack {
                LinearGradient(colors: [.accentColor.opacity(0.7), .accentColor.opacity(0.35)],
                               startPoint: .leading, endPoint: .trailing)
                Label("Banner image not found", systemImage: "photo")
                    .foregroundStyle(.white)
            }
            .frame(height: 110)
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 12, topTrailingRadius: 12))
        }
    }

    @ViewBuilder
    private func blockView(_ block: DialogMarkdown.Block) -> some View {
        switch block {
        case .heading(let text):
            Text(inline(text)).font(.title3.bold())
        case .paragraph(let text):
            Text(inline(text))
        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•")
                Text(inline(text))
            }
        }
    }

    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    private func fakeButton(_ title: String, prominent: Bool) -> some View {
        Text(title)
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
            .foregroundStyle(prominent ? .white : .primary)
            .background(prominent ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary), in: Capsule())
    }
}
