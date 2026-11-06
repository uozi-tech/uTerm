import UDesignKit
import SwiftUI
import SwiftData
import Combine

/// 设置 · 安全：启动时验证身份（原在「通用」），以及 SSH 密钥 / 主机分组 / 已知主机指纹三个管理窗口的入口。
///
/// 应用锁开关与 iOS 同走 `AppLockToggleModel`：开启前先验证一次（Touch ID 或登录密码），关闭直接生效。
struct SecuritySettingsView: View {
    @State private var appLock = AppLockToggleModel()
    @Environment(\.openWindow) private var openWindow
    @Environment(\.modelContext) private var context

    /// 行尾的条数。走 `fetchCount` 不物化对象（见 `LibraryCounts`），出现时与本机每次保存后重取。
    @State private var counts = LibraryCounts()

    var body: some View {
        SettingsScroll {
            SettingsPageHeader(title: "安全", subtitle: String(localized: "应用锁与密钥"))

            SettingsGroup(title: "应用锁",
                          footer: String(localized: "开启前先验证一次；下次启动 uTerm 时要求 Touch ID 或登录密码。")) {
                SettingsRow(label: "启动时验证身份") {
                    UDToggle(Binding(get: { appLock.isOn }, set: { appLock.set($0) }))
                }
            }
            SettingsGroup(title: "密钥、分组与指纹",
                          footer: String(localized: "密钥与分组经 iCloud 同步到你的其他设备；删除已知主机指纹后，下次连接该主机会重新确认。")) {
                SettingsListRow(icon: "key.fill", tint: UD.warning, title: String(localized: "SSH 密钥"),
                                subtitle: String(localized: "\(counts.keys) 把密钥 · 生成、导入与查看")) {
                    UDButton(title: "打开…", style: .secondary) { openWindow(id: "keys") }
                }
                SettingsListRow(icon: "tag.fill", tint: UD.info, title: String(localized: "主机分组"),
                                subtitle: String(localized: "\(counts.groups) 个分组 · 建分组、改名、调整顺序")) {
                    UDButton(title: "打开…", style: .secondary) { openWindow(id: "groups") }
                }
                SettingsListRow(icon: "checkmark.shield.fill", tint: UD.success, title: String(localized: "已知主机指纹"),
                                subtitle: String(localized: "\(counts.knownHosts) 台已信任的主机")) {
                    UDButton(title: "打开…", style: .secondary) { openWindow(id: "known-hosts") }
                }
            }
        }
        .alert(AppLockToggleModel.unavailableTitle, isPresented: $appLock.unavailableAlert) {
            Button("好", role: .cancel) {}
        } message: {
            Text(AppLockToggleModel.unavailableMessage)
        }
        .onAppear(perform: refreshCounts)
        // 后台上下文（局域网覆盖）也会发 didSave，回主线程再刷新。
        .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave)
            .receive(on: DispatchQueue.main)) { _ in
            refreshCounts()
        }
    }

    private func refreshCounts() {
        counts = LibraryCounts.fetch(in: context)
    }
}
