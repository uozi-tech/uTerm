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

    var body: some View {
        VStack(spacing: 0) {
            if weak {
                weakHeader
                weakBanner
                weakButtons
            } else {
                header
                fingerprints
                if !unknown { mismatchBanner }
                buttons
            }
        }
    }

    // MARK: - 连接方式变弱了（没有指纹；「取消」是醒目的那个，「仍然连接」在旁边）

    private var weakHeader: some View {
        HStack(alignment: .top, spacing: 13) {
            MIcon(name: "warn", size: 19, color: tint)
                .frame(width: 38, height: 38)
                .background(tint.opacity(0.14))
                .clipShape(RoundedRectangle(cornerRadius: MRadius.inner(of: MRadius.dialog, inset: 16)))
            VStack(alignment: .leading, spacing: 5) {
                Text(WeakAlgorithmsCopy.title(challenge))
                    .font(M.sans(16, weight: .semibold))
                    .foregroundStyle(M.text)
                Text(WeakAlgorithmsCopy.summary(challenge))
                    .font(M.sans(12.5)).foregroundStyle(M.text2).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 14)
        .overlay(alignment: .bottom) { Rectangle().fill(M.divider).frame(height: 1) }
    }

    private var weakBanner: some View {
        Text(WeakAlgorithmsCopy.advice(challenge))
            .font(M.sans(12.5)).foregroundStyle(M.text2).lineSpacing(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(11)
            .background(tint.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: MRadius.md))
            .padding(.horizontal, 18).padding(.top, 14)
    }

    private var weakButtons: some View {
        HStack(spacing: 10) {
            MBtn(title: String(localized: "仍然连接", comment: "连接方式变弱时照样连接"), kind: .secondary, full: true,
                 height: 46, action: onTrust)
            MBtn(title: String(localized: "取消"), kind: .primary, full: true, height: 46, action: onCancel)
        }
        .padding(.horizontal, 16).padding(.top, 30).padding(.bottom, 16)
        .overlay(alignment: .top) { Rectangle().fill(M.divider).frame(height: 1) }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 13) {
            MIcon(name: unknown ? "shield" : "warn", size: 19, color: tint)
                .frame(width: 38, height: 38)
                .background(tint.opacity(0.14))
                // 与弹窗外框同心：图标块距顶边 16pt
                .clipShape(RoundedRectangle(cornerRadius: MRadius.inner(of: MRadius.dialog, inset: 16)))
            VStack(alignment: .leading, spacing: 5) {
                Text(unknown ? "首次连接到此主机" : "主机密钥已变化")
                    .font(M.sans(16, weight: .semibold))
                    .foregroundStyle(unknown ? M.text : M.danger)
                Text(unknown
                     ? "主机 \(challenge.host)（端口 \(String(challenge.port))）的密钥尚未被信任。"
                     : "\(challenge.host):\(String(challenge.port)) 出示的主机密钥与已信任的不同。这可能是主机重装过系统，也可能是中间人攻击。")
                    .font(M.sans(12.5)).foregroundStyle(M.text2).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 14)
        .overlay(alignment: .bottom) { Rectangle().fill(M.divider).frame(height: 1) }
    }

    private var fingerprints: some View {
        VStack(alignment: .leading, spacing: 13) {
            if let old = challenge.oldFingerprint {
                fpRow(label: String(localized: "已信任", comment: "已信任的主机密钥指纹"), value: old, dim: true)
            }
            fpRow(label: unknown ? String(localized: "密钥指纹") : String(localized: "本次出示"), value: challenge.newFingerprint, danger: !unknown)
        }
        .padding(.horizontal, 18).padding(.top, 16)
    }

    private var mismatchBanner: some View {
        Text("如果你最近没有重装这台主机，不要继续，先通过其他渠道与管理员确认。")
            .font(M.sans(12.5)).foregroundStyle(M.danger).lineSpacing(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(11)
            .background(M.danger.opacity(0.08))
            .overlay(RoundedRectangle(cornerRadius: MRadius.md).stroke(M.danger.opacity(0.25), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: MRadius.md))
            .padding(.horizontal, 18).padding(.top, 14)
    }

    private var buttons: some View {
        HStack(spacing: 10) {
            MBtn(title: String(localized: "取消"), kind: .secondary, full: true, height: 46, action: onCancel)
            MBtn(title: unknown ? String(localized: "信任并连接") : String(localized: "信任新密钥"),
                 icon: unknown ? "shield" : nil,
                 kind: unknown ? .primary : .danger, full: true, height: 46, action: onTrust)
        }
        // 底边距 16pt：`MBtn` 的 `lg` 圆角 + 16 = `MRadius.dialog`，按钮与弹窗外框同心
        .padding(.horizontal, 16).padding(.top, 30).padding(.bottom, 16)
        .overlay(alignment: .top) { Rectangle().fill(M.divider).frame(height: 1) }
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
