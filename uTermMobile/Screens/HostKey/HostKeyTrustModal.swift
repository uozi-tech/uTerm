import SwiftUI

/// 主机密钥信任弹层（设计稿 `HostKeyModal`）。首次连接（unknown）/ 密钥变化（mismatch）两态，外加
/// 「连接方式变弱了」（`.weakAlgorithms`，不是主机密钥的问题，没有指纹，取消是醒目的那个）。
/// 由根视图在 `HostKeyChallengeRelay.pendingChallenge` 非空时居中呈现；裁决经 relay 续延回 SSH 层。
struct HostKeyTrustModal: View {
    let challenge: HostKeyChallenge
    var onCancel: () -> Void
    var onTrust: () -> Void
    @Environment(\.mAccent) private var accent

    private var unknown: Bool { if case .unknown = challenge.kind { return true }; return false }
    private var weak: Bool { challenge.isWeakAlgorithms }
    private var tint: Color { unknown ? accent : (weak ? M.warning : M.danger) }

    /// 弹窗四边统一 16pt：图标块（`MRadius.inner(of: dialog, inset: 16)`）与按钮（`lg` + 16 = `dialog`）
    /// 都和外框同心；左右也是 16，标题、指纹、提示框和按钮的左边对齐成一条线。
    private static let inset: CGFloat = 16

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if weak {
                headerRow(icon: "warn",
                          title: WeakAlgorithmsCopy.title(challenge),
                          titleColor: M.text,
                          message: WeakAlgorithmsCopy.summary(challenge))
                banner(WeakAlgorithmsCopy.advice(challenge), color: M.text2, fill: tint.opacity(0.08), stroke: nil)
                    .padding(.top, 14)
                // 连接方式变弱了：没有指纹；「取消」是醒目的那个，「仍然连接」在旁边
                buttonRow {
                    MBtn(title: String(localized: "仍然连接", comment: "连接方式变弱时照样连接"), kind: .secondary, full: true,
                         height: 46, action: onTrust)
                    MBtn(title: String(localized: "取消"), kind: .primary, full: true, height: 46, action: onCancel)
                }
            } else {
                headerRow(icon: unknown ? "shield" : "warn",
                          title: unknown ? String(localized: "首次连接到此主机") : String(localized: "主机密钥已变化"),
                          titleColor: unknown ? M.text : M.danger,
                          message: unknown
                            ? String(localized: "主机 \(challenge.host)（端口 \(String(challenge.port))）的密钥尚未被信任。")
                            : String(localized: "\(challenge.host):\(String(challenge.port)) 出示的主机密钥与已信任的不同。这可能是主机重装过系统，也可能是中间人攻击。"))
                fingerprints.padding(.top, 16)
                if !unknown {
                    banner(String(localized: "如果你最近没有重装这台主机，不要继续，先通过其他渠道与管理员确认。"),
                           color: M.danger, fill: M.danger.opacity(0.08), stroke: M.danger.opacity(0.25))
                        .padding(.top, 14)
                }
                buttonRow {
                    MBtn(title: String(localized: "取消"), kind: .secondary, full: true, height: 46, action: onCancel)
                    MBtn(title: unknown ? String(localized: "信任并连接") : String(localized: "信任新密钥"),
                         icon: unknown ? "shield" : nil,
                         kind: unknown ? .primary : .danger, full: true, height: 46, action: onTrust)
                }
            }
        }
        .padding(Self.inset)
    }

    private func headerRow(icon: String, title: String, titleColor: Color, message: String) -> some View {
        HStack(alignment: .top, spacing: 13) {
            MIcon(name: icon, size: 19, color: tint)
                .frame(width: 38, height: 38)
                .background(tint.opacity(0.14))
                // 与弹窗外框同心：图标块距顶边 16pt
                .clipShape(RoundedRectangle(cornerRadius: MRadius.inner(of: MRadius.dialog, inset: Self.inset)))
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(M.sans(16, weight: .semibold))
                    .foregroundStyle(titleColor)
                    .fixedSize(horizontal: false, vertical: true)
                Text(message)
                    .font(M.sans(12.5)).foregroundStyle(M.text2).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    /// 提示框：多行文字按实际高度撑开（少了 `fixedSize` 时第二行会溢出框底）。
    private func banner(_ text: String, color: Color, fill: Color, stroke: Color?) -> some View {
        Text(text)
            .font(M.sans(12.5)).foregroundStyle(color).lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(fill)
            .overlay(RoundedRectangle(cornerRadius: MRadius.md).stroke(stroke ?? .clear, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: MRadius.md))
    }

    private func buttonRow<Buttons: View>(@ViewBuilder _ buttons: () -> Buttons) -> some View {
        HStack(spacing: 10) { buttons() }
            .padding(.top, 20)
    }

    private var fingerprints: some View {
        VStack(alignment: .leading, spacing: 13) {
            if let old = challenge.oldFingerprint {
                fpRow(label: String(localized: "已信任", comment: "已信任的主机密钥指纹"), value: old, dim: true)
            }
            fpRow(label: unknown ? String(localized: "密钥指纹") : String(localized: "本次出示"), value: challenge.newFingerprint, danger: !unknown)
        }
    }

    private func fpRow(label: String, value: String, dim: Bool = false, danger: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased()).font(M.sans(10.5, weight: .medium)).tracking(0.5).foregroundStyle(M.text4)
            HStack(spacing: 10) {
                Text(value).font(M.mono(12))
                    .foregroundStyle(dim ? M.text3 : (danger ? M.danger : M.text))
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 6)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(M.fillFaint)
            // danger 为状态描边（密钥不匹配警示），保留；常态不描边
            .overlay(RoundedRectangle(cornerRadius: MRadius.md).stroke(danger ? M.danger.opacity(0.5) : .clear, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: MRadius.md))
        }
    }
}
