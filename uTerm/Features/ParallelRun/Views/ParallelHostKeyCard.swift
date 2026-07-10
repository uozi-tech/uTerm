import SwiftUI

/// 并行执行窗口里「主机指纹未信任」的内联提示卡 —— 展示指纹 +「信任并重试」。
///
/// 并行 / Agent 路径建连时 host-key 审批恒拒绝（无交互入口），因此首次连接的未知指纹、
/// 或指纹变更的主机会**连接失败**。此卡复用与终端 / SFTP 征询同源的 `HostKeyChallenge`
/// 把真实指纹摆给用户：确认无误后点「信任并重试」，仅重跑该台 —— 用一个会信任新密钥的
/// 执行器重建连接，握手成功即把密钥写入信任库（TOFU）。
///
/// 未知指纹用中性「警示」色（`UD.caution`）；指纹变更（可能中间人）用红色（`UD.danger`）醒目警告。
struct HostKeyRetryCard: View {
    let challenge: HostKeyChallenge
    /// 用户点「信任并重试」。
    let onTrust: () -> Void

    private var isMismatch: Bool { challenge.kind == .mismatch }
    private var tint: Color { isMismatch ? UD.danger : UD.caution }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Image(systemName: isMismatch ? "exclamationmark.triangle.fill" : "lock.shield")
                    .font(.system(size: 12)).foregroundStyle(tint)
                Text(isMismatch ? "主机密钥已变化" : "主机指纹未信任")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(tint)
            }
            Text(isMismatch
                 ? "\(challenge.host):\(String(challenge.port)) 出示的主机密钥与已信任的不一致（可能是服务器重装，也可能是中间人攻击）。请核对指纹，确认无误后再信任。"
                 : "\(challenge.host):\(String(challenge.port)) 的主机密钥尚未被信任，因此并行执行时直接拒绝了连接。")
                .font(.system(size: 11.5)).foregroundStyle(UD.text3)
                .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            if isMismatch, let old = challenge.oldFingerprint {
                fingerprintRow("已信任", old)
            }
            fingerprintRow(isMismatch ? "本次出示" : "指纹", challenge.newFingerprint)

            HStack {
                Spacer(minLength: 0)
                Button(action: onTrust) {
                    Text(isMismatch ? "我了解风险，信任并重试" : "信任并重试")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(tint)
            }
        }
        .padding(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(tint.opacity(0.10)))
    }

    @ViewBuilder
    private func fingerprintRow(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 10)).foregroundStyle(UD.text4)
            Text(value).font(.system(size: 11, design: .monospaced)).foregroundStyle(UD.text2)
                .textSelection(.enabled).lineLimit(1).truncationMode(.middle).help(value)
        }
    }
}
