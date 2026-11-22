import SwiftUI

/// 设置 › 安全：应用锁 / 密钥 / 分组 / 指纹 / 端口转发规则。
/// 应用锁开关走共享的 `AppLockToggleModel`（开启前先验证一次）；「无法开启」的提示挂在根页。
struct SettingsSecuritySection: View {
    let counts: LibraryCounts
    let appLock: AppLockToggleModel

    /// 当前机器的生物识别类型（文案 + 图标），用于应用锁开关行。
    private var biometry: (title: String, icon: String) { MobileBiometry.describe() }

    var body: some View {
        MInsetGroup(header: String(localized: "安全")) {
            MInsetRow(icon: biometry.icon, label: String(localized: "\(biometry.title) 解锁"),
                      sub: String(localized: "回到 uTerm 时需验证身份"),
                      trailing: AnyView(MSwitch(on: Binding(get: { appLock.isOn },
                                                             set: { appLock.set($0) }))))
            NavigationLink { KeysScreen() } label: {
                MInsetRow(icon: "key", label: String(localized: "SSH 密钥"), value: "\(counts.keys)", chevron: true)
            }.buttonStyle(MRowStyle())
            NavigationLink { GroupsScreen() } label: {
                MInsetRow(icon: "tag", label: String(localized: "主机分组"), value: "\(counts.groups)", chevron: true)
            }.buttonStyle(MRowStyle())
            NavigationLink { FingerprintsView() } label: {
                MInsetRow(icon: "shield", label: String(localized: "已知主机指纹"), value: "\(counts.knownHosts)", chevron: true)
            }.buttonStyle(MRowStyle())
            // 移动端没有端口转发的管理页（转发是 macOS 端的能力），这一行只报数。
            // 改前带着 `chevron: true` 却没有 `onTap` —— 看着可点、点了没反应。
            MInsetRow(icon: "forward", label: String(localized: "端口转发规则"), value: "\(counts.forwards)",
                      last: true)
        }
    }
}
