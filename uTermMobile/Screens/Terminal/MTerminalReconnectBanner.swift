import SwiftUI

/// 终端顶部的断线提示。画面还停在断线前，这时按键发不出去，不说的话看起来就像卡住了。
struct MTerminalReconnectBanner: View {
    let notice: LocalizedStringKey

    var body: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.mini)
            Text(notice)
                .font(.footnote)
                .foregroundStyle(M.text)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .padding(.top, 8)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }
}

/// 终端顶部的「已断开」提示：会话结束了（shell 退出、连接断了又接不回），画面停在最后的样子。点一下在这个标签上重新连接。
struct MTerminalDisconnectedBanner: View {
    let onReconnect: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text("连接已断开")
                .font(.footnote)
                .foregroundStyle(M.text2)
            Button(action: onReconnect) {
                Text("重新连接")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(M.accent)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .background(.regularMaterial, in: Capsule())
        .padding(.top, 8)
    }
}
