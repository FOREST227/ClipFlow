import SwiftUI

struct QuickPastePanelHeader: View {
    let preferredTargetName: String?
    let palette: ClipFlowPalette
    let onClose: () -> Void

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

            Button("关闭", action: onClose)
                .buttonStyle(ClipFlowActionButtonStyle(fill: palette.secondaryButtonFill))
        }
    }
}
