import SwiftUI

/// 删除密钥的确认弹层（设计稿 `keys.jsx` 的 `KeyDeleteConfirm`）。居中暗色卡片
/// 罩在半透明遮罩上，提示受影响主机数。
struct KeyDeleteConfirm: View {
    let key: SSHKey
    let hostCount: Int
    let onCancel: () -> Void
    let onConfirm: () -> Void

    private let danger = Color(hex: 0xF87171)

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
                .onTapGesture(perform: onCancel)
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(danger.opacity(0.14))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(danger.opacity(0.3), lineWidth: 1))
                        .frame(width: 36, height: 36)
                        .overlay(Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 16, weight: .medium)).foregroundStyle(danger))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("删除密钥「\(key.name)」？")
                            .font(.system(size: 14, weight: .medium)).foregroundStyle(UD.text)
                        Text(message).font(.system(size: 12)).foregroundStyle(UD.text2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack(spacing: 8) {
                    Spacer()
                    UDButton(title: "取消", style: .secondary, action: onCancel)
                    UDButton(title: "删除", style: .danger, action: onConfirm)
                }
            }
            .padding(.horizontal, 22).padding(.top, 20).padding(.bottom, 16)
            .frame(width: 400)
            .background(RoundedRectangle(cornerRadius: 12).fill(UD.overlayHi))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(UD.borderHi, lineWidth: 1))
            .shadow(color: .black.opacity(0.6), radius: 30, y: 18)
        }
    }

    private var message: String {
        if hostCount > 0 {
            return "使用此密钥的 \(hostCount) 台主机将无法连接。操作不可恢复。"
        }
        return "此密钥未被任何主机使用。操作不可恢复。"
    }
}
