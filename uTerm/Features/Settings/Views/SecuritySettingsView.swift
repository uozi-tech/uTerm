import UDesignKit
import SwiftUI
import SwiftData
import Combine

/// 设置 · 安全：启动时验证身份（原在「通用」），以及 SSH 密钥 / 主机分组 / 已知主机指纹三个管理窗口的入口。
///
/// mac 的应用锁开关直接写偏好（下次启动生效），不走 iOS「先验证一次再开启」的流程。
struct SecuritySettingsView: View {
    @AppStorage(AppLockPreference.key) private var requireAuthAtLaunch = AppLockPreference.defaultValue
    @Environment(\.openWindow) private var openWindow
    @Environment(\.modelContext) private var context

    /// 行尾的条数。走 `fetchCount` 不物化对象（见 `LibraryCounts`），出现时与本机每次保存后重取。
    @State private var counts = LibraryCounts()

    var body: some View {
        SettingsScroll {
            SettingsGroup(title: "应用锁") {
                SettingsRow(label: "启动时验证身份",
                            hint: "下次启动 uTerm 时要求 Touch ID 或登录密码 · 改动下次启动生效") {
                    UDToggle($requireAuthAtLaunch)
                }
            }
            SettingsGroup(title: "密钥、分组与指纹") {
                SettingsRow(label: "SSH 密钥", hint: "生成、导入与查看本机保存的 SSH 密钥，经 iCloud 同步到其他设备。") {
                    UDButton(title: "打开…", style: .secondary) { openWindow(id: "keys") }
                }
                SettingsRow(label: "主机分组", hint: "给主机建分组、改名、调整顺序。") {
                    UDButton(title: "打开…", style: .secondary) { openWindow(id: "groups") }
                }
                SettingsRow(label: "已知主机指纹",
                            hint: "已信任 \(counts.knownHosts) 台主机的密钥指纹；删除后下次连接会重新确认。") {
                    UDButton(title: "打开…", style: .secondary) { openWindow(id: "known-hosts") }
                }
            }
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
