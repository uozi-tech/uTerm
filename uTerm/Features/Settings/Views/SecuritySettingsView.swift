import UDesignKit
import SwiftUI

/// 设置 · 安全：启动时验证身份（原在「通用」），以及 SSH 密钥 / 主机分组两个管理窗口的入口。
///
/// mac 的应用锁开关直接写偏好（下次启动生效），不走 iOS「先验证一次再开启」的流程。
/// 已知主机指纹的管理界面 mac 还没有（iOS 有 `FingerprintsView`），待补。
struct SecuritySettingsView: View {
    @AppStorage(AppLockPreference.key) private var requireAuthAtLaunch = AppLockPreference.defaultValue
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        SettingsScroll {
            SettingsGroup(title: "应用锁") {
                SettingsRow(label: "启动时验证身份",
                            hint: "下次启动 uTerm 时要求 Touch ID 或登录密码 · 改动下次启动生效") {
                    UDToggle($requireAuthAtLaunch)
                }
            }
            SettingsGroup(title: "密钥与分组") {
                SettingsRow(label: "SSH 密钥", hint: "生成、导入与查看本机保存的 SSH 密钥，经 iCloud 同步到其他设备。") {
                    UDButton(title: "打开…", style: .secondary) { openWindow(id: "keys") }
                }
                SettingsRow(label: "主机分组", hint: "给主机建分组、改名、调整顺序。") {
                    UDButton(title: "打开…", style: .secondary) { openWindow(id: "groups") }
                }
            }
        }
    }
}
