import AppKit
import SwiftUI

/// An approximation of how swiftDialog renders the watcher's dialog: banner (or org title), icon, Markdown
/// message (with its variables filled in) and one, two or three buttons. It is laid out at the dialog's real point size and scaled to the space
/// available, so the rule's width and height (and the banner and icon sizes) show in proportion.
/// "Live Preview" and "Simulate dialog" show the real thing.
struct DialogPreviewView: View {
    let rule: RuleModel
    let settings: RuleSettings

    /// Stand-ins for swiftDialog's defaults when Settings leaves the size alone.
    private static let defaultBannerHeight = 130
    private static let defaultIconSize = 150

    private var width: CGFloat { CGFloat(max(rule.dialogWidth ?? DialogCommand.defaultWidth, RuleModel.minimumDialogSize)) }
    private var height: CGFloat { CGFloat(max(rule.dialogHeight ?? DialogCommand.defaultHeight, RuleModel.minimumDialogSize)) }

    var body: some View {
        Color.clear
            .aspectRatio(width / height, contentMode: .fit)
            .overlay {
                GeometryReader { geometry in
                    dialog
                        .frame(width: width, height: height)
                        .scaleEffect(geometry.size.width / width, anchor: .topLeading)
                }
            }
            // A picture, not controls: the scaled mock must never take clicks meant for what's around it.
            .allowsHitTesting(false)
            .shadow(color: .black.opacity(0.3), radius: 14, y: 6)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Dialog preview, \(Int(width)) by \(Int(height)) points")
    }

    private var dialog: some View {
        let document = DialogMarkdown.parse(MessageVariables.expand(rule.dialogMessage, rule: rule, settings: settings))
        return VStack(spacing: 0) {
            header
            HStack(alignment: .top, spacing: 28) {
                if rule.dialogShowIcon ?? true { icon }
                VStack(alignment: horizontal, spacing: 14) {
                    if let title = document.title {
                        Text(title).font(.system(size: 30, weight: .bold))
                        Divider()
                    }
                    ForEach(Array(document.blocks.enumerated()), id: \.offset) { _, block in
                        blockView(block)
                    }
                }
                .font(.system(size: 20))
                .multilineTextAlignment(textAlignment)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: Alignment(horizontal: horizontal, vertical: vertical))
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .frame(maxHeight: .infinity, alignment: .top)
            .clipped()
            HStack(spacing: 12) {
                if rule.infoButtonAction != nil {
                    fakeButton(rule.infoButtonText ?? RuleModel.defaultInfoButtonText, prominent: false)
                }
                Spacer()
                if let dismiss = rule.dismissButtonText {
                    fakeButton(dismiss, prominent: false)
                }
                fakeButton(rule.buttonText ?? "OK", prominent: true)
            }
            .padding(20)
        }
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(.quaternary, lineWidth: 1))
    }

    private var horizontal: HorizontalAlignment {
        switch rule.dialogMessageAlignment ?? .left {
        case .left: .leading
        case .center: .center
        case .right: .trailing
        }
    }

    private var textAlignment: TextAlignment {
        switch rule.dialogMessageAlignment ?? .left {
        case .left: .leading
        case .center: .center
        case .right: .trailing
        }
    }

    private var vertical: VerticalAlignment {
        switch rule.dialogMessagePosition ?? .top {
        case .top: .top
        case .center: .center
        case .bottom: .bottom
        }
    }

    @ViewBuilder
    private var header: some View {
        let bannerHeight = CGFloat(settings.bannerHeight ?? Self.defaultBannerHeight)
        if !DialogCommand.showsBanner(rule, settings: settings) {
            // Without a banner the watcher passes --title "<org>".
            Text(settings.orgNameFriendly)
                .font(.system(size: 28, weight: .bold))
                .frame(maxWidth: .infinity)
                .padding(.top, 24)
        } else if let image = NSImage(contentsOfFile: settings.bannerImagePath) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(height: bannerHeight)
                .frame(maxWidth: .infinity)
                .clipped()
        } else {
            ZStack {
                LinearGradient(colors: [.accentColor.opacity(0.7), .accentColor.opacity(0.35)],
                               startPoint: .leading, endPoint: .trailing)
                Label("Banner image not found on this Mac", systemImage: "photo")
                    .font(.system(size: 20))
                    .foregroundStyle(.white)
            }
            .frame(height: bannerHeight)
        }
    }

    /// The icon from Settings (`--icon`), or the watcher's standard red shield.
    @ViewBuilder
    private var icon: some View {
        let size = CGFloat(settings.iconSize ?? Self.defaultIconSize)
        if !settings.iconPath.isEmpty, let image = NSImage(contentsOfFile: settings.iconPath) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        } else {
            Image(systemName: settings.iconPath.isEmpty ? "exclamationmark.shield.fill" : "photo")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(settings.iconPath.isEmpty ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func blockView(_ block: DialogMarkdown.Block) -> some View {
        switch block {
        case .heading(let text):
            Text(inline(text)).font(.system(size: 24, weight: .bold))
        case .paragraph(let text):
            Text(inline(text))
        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
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
            .font(.system(size: 18))
            .padding(.horizontal, 26)
            .padding(.vertical, 8)
            .foregroundStyle(prominent ? .white : .primary)
            .background(prominent ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary), in: Capsule())
    }
}
