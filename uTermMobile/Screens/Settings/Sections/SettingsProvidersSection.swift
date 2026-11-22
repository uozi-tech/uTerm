import SwiftUI

/// 设置 › 模型服务（对齐 macOS 设置的「模型服务」页）。
struct SettingsProvidersSection: View {
    let providerCount: Int

    var body: some View {
        MInsetGroup(header: "AI", footer: String(localized: "Agent 用到的模型服务。服务列表经 iCloud 与 Mac 同步，API Key 经 iCloud 钥匙串同步。")) {
            NavigationLink { ProvidersScreen() } label: {
                MInsetRow(icon: "spark", label: String(localized: "模型服务"),
                          sub: providerCount == 0 ? String(localized: "尚未配置") : nil,
                          value: providerCount == 0 ? nil : "\(providerCount)",
                          chevron: true, last: true)
            }.buttonStyle(MRowStyle())
        }
    }
}
