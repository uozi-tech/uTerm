import UDesignKit
import SwiftUI

/// 主机密钥征询弹窗内容。未知主机用中性样式；密钥不匹配用红色醒目警告；连接方式变弱了（`.weakAlgorithms`）
/// 用警示色，「取消」是默认按钮（回车），「仍然连接」要点。
struct HostKeyPromptView: View {
    let challenge: HostKeyChallenge
    /// true = 信任并继续；false = 取消。
    let decide: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch challenge.kind {
            case .unknown:
                Label("首次连接到此主机", systemImage: "lock.shield")
                    .font(.headline)
                Text("\(challenge.host):\(String(challenge.port)) 的主机密钥尚未被信任。")
                    .foregroundStyle(UD.text3)
                fingerprintRow(String(localized: "密钥指纹"), challenge.newFingerprint)
            case .mismatch:
                Label("主机密钥已变化", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(UD.danger)
                Text("\(challenge.host):\(String(challenge.port)) 出示的主机密钥与已信任的不同。这可能是主机重装过系统，也可能是中间人攻击。")
                    .foregroundStyle(UD.danger)
                if let old = challenge.oldFingerprint {
                    fingerprintRow(String(localized: "已信任", comment: "主机密钥指纹：此前已信任的那一份"), old)
                }
                fingerprintRow(String(localized: "本次出示", comment: "主机密钥指纹：这次连接主机出示的那一份"),
                               challenge.newFingerprint)
            case .weakAlgorithms:
                Label(WeakAlgorithmsCopy.title(challenge), systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(UD.caution)
                Text(WeakAlgorithmsCopy.summary(challenge))
                    .fixedSize(horizontal: false, vertical: true)
                Text(WeakAlgorithmsCopy.advice)
                    .foregroundStyle(UD.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if challenge.isWeakAlgorithms {
                // 取消是安全的那一边：回车也是它。
                HStack {
                    Spacer()
                    Button(String(localized: "仍然连接", comment: "连接方式变弱时照样连接")) { decide(true) }
                    Button("取消") { decide(false) }
                        .keyboardShortcut(.defaultAction)
                }
            } else {
                HStack {
                    Button("取消") { decide(false) }
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button(challenge.kind == .unknown ? "信任并连接" : "我了解风险，信任新密钥") {
                        decide(true)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(challenge.kind == .mismatch ? UD.danger : UD.accent)
                }
            }
        }
        .padding(20)
        .frame(width: 460)
        .onExitCommand { decide(false) }
    }

    @ViewBuilder
    private func fingerprintRow(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(UD.text3)
                .accessibilityAddTraits(.isHeader)
            Text(value).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                .help(value)
        }
    }
}
