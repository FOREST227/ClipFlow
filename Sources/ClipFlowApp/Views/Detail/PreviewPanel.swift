import AppKit
import SwiftUI

struct PreviewPanel: View {
    let item: ClipboardItem
    let displayedText: String
    let palette: ClipFlowPalette
    @ObservedObject var store: ClipFlowStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(item.sourceApp)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.secondary)
                Spacer()
                Text(item.timeLabel)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.secondary)
            }

            if item.isImage {
                VStack(alignment: .leading, spacing: 12) {
                    ClipThumbnailView(
                        store: store,
                        item: item,
                        height: 260,
                        cornerRadius: 22,
                        contentMode: .fit,
                        insetPreview: true
                    )

                    Text(displayedText)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(palette.softFill)
                )
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text(displayedText)
                        .font(.system(size: item.kind == .code ? 12 : 14, weight: .medium, design: item.kind == .code ? .monospaced : .rounded))
                        .foregroundStyle(Color.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(palette.softFill)
                        )

                    if let linkURL = item.primaryURL {
                        Button {
                            NSWorkspace.shared.open(linkURL)
                        } label: {
                            Label("访问链接", systemImage: "arrow.up.forward.app")
                                .font(.system(size: 13, weight: .semibold))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(ClipButtonStyle(fill: ClipCategory.links.tint.opacity(0.14), foreground: ClipCategory.links.tint))
                    }
                }
            }
        }
    }
}

struct DetailActionLabel: View {
    let title: String
    let icon: String
    let tint: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
            Text(title)
        }
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(tint)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(tint.opacity(0.12))
        )
    }
}

struct PrivacyFactRow: View {
    let title: String
    let value: String
    let tint: Color

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.secondary)

            Spacer()

            Text(value)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(tint)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule(style: .continuous)
                        .fill(tint.opacity(0.12))
                )
        }
    }
}

