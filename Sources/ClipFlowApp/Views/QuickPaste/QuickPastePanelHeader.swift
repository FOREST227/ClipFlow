import SwiftUI

struct QuickPastePanelHeader: View {
    let preferredTargetName: String?
    let palette: ClipFlowPalette
    var onSwitchToFan: (() -> Void)? = nil
    let onClose: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack {
            HStack(spacing: 8) {
                ClipFlowBrandMark(icon: "cursorarrow.rays", size: 28)
                Text("快速粘贴")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                if let preferredTargetName, !preferredTargetName.isEmpty {
                    Text("→ \(preferredTargetName)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary).lineLimit(1)
                        .help("粘贴到 \(preferredTargetName)")
                }
            }

            Spacer()

            if let onSwitchToFan {
                Button(action: onSwitchToFan) {
                    HStack(spacing: 4) {
                        Image(systemName: "rectangle.on.rectangle.angled")
                            .font(.system(size: 10, weight: .semibold))
                        Text("轮播")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(ClipFlowPalette.secondaryText(for: colorScheme))
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(palette.secondaryButtonFill, in: Capsule(style: .continuous))
                    .overlay(Capsule(style: .continuous).strokeBorder(palette.border, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("切换到扇形叠卡轮播")
                .accessibilityLabel("切换到扇形叠卡轮播")
            }

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 22, height: 22)
                    .foregroundStyle(.secondary)
                    .background(palette.secondaryButtonFill, in: Circle())
                    .overlay(Circle().strokeBorder(palette.border, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭")
            .help("关闭")
        }
        .frame(minHeight: ClipFlowLayout.controlHeight)
    }
}
