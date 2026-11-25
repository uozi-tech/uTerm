import SwiftUI

/// 终端顶部的断线提示。画面还停在断线前，这时按键发不出去，不说的话看起来就像卡住了。
struct MTerminalReconnectBanner: View {
    let notice: LocalizedStringKey
    /// 上一次重连为什么没连上（服务器拒绝连接、不可达、超时……）。有就在下面一行说明，nil 不显示。
    var failure: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(notice)
                    .font(.footnote)
                    .foregroundStyle(M.text)
            }
            if let failure {
                Text("仍然连不上：\(failure)")
                    .font(.caption)
                    .foregroundStyle(M.text2)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: failure == nil ? 100 : 14, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }
}

/// 终端顶部的「连不回去、要你处理」提示：自动重连停下了（服务器拒绝了凭据、主机密钥被拒、握手不成），
/// 主机上的会话还在。处理好（改密码、确认主机密钥）之后点重试，接回同一个会话。
struct MTerminalAttentionBanner: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(M.warning)
            Text("连接没能恢复：\(message)")
                .font(.footnote)
                .foregroundStyle(M.text)
                .lineLimit(2)
            Button(action: onRetry) {
                Text("重试")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(M.accent)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 2)
        .background(.regularMaterial, in: Capsule())
        .padding(.horizontal, 12)
        .padding(.top, 8)
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
