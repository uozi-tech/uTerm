import UDesignKit
import SwiftUI

/// 主机密钥征询弹窗内容。未知主机用中性样式；密钥不匹配用红色醒目警告。
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
                fingerprintRow("密钥指纹", challenge.newFingerprint)
            case .mismatch:
                Label("主机密钥已变化", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(UD.danger)
                Text("\(challenge.host):\(String(challenge.port)) 出示的主机密钥与已信任的不同。这可能是服务器重装，也可能是中间人攻击。")
                    .foregroundStyle(UD.danger)
                if let old = challenge.oldFingerprint {
                    fingerprintRow("已信任", old)
                }
                fingerprintRow("本次出示", challenge.newFingerprint)
            }
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
        .padding(20)
        .frame(width: 460)
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
