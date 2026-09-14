import SwiftUI

/// 移动端局域网同步入口：Mac 广播后，用户输入 Mac 设置页显示的配对码再同步。
struct LANSyncSettingsSection: View {
    @Environment(LANSyncCoordinator.self) private var lanSync
    @AppStorage("lanSync.pairingCode") private var pairingCode = ""

    var body: some View {
        MInsetGroup(header: "局域网同步", footer: "手机与 Mac 需连接同一 Wi-Fi。手机同步时会以 Mac 的本地数据覆盖当前设备配置。密码、私钥和 API Key 不会传输。") {
            MInsetRow(icon: "wifi", label: "Mac 设备", sub: lanSync.status.label,
                      value: lanSync.peers.first?.name ?? "未发现", last: lanSync.peers.isEmpty)

            if !lanSync.peers.isEmpty {
                MInsetRow(label: "配对码", sub: "在 Mac 的设置 › 高级中查看",
                          trailing: AnyView(
                              TextField("6 位配对码", text: $pairingCode)
                                  .keyboardType(.numberPad)
                                  .multilineTextAlignment(.trailing)
                                  .font(M.mono(14))
                                  .foregroundStyle(M.text)
                                  .frame(width: 110)))
            }

            MBtn(title: "同步数据", icon: "arrow.triangle.2.circlepath", kind: .secondary,
                 full: true, height: 46,
                 disabled: lanSync.peers.isEmpty || pairingCode.count != 6 || isSyncing) {
                lanSync.syncNow(pairingCode: pairingCode)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    private var isSyncing: Bool {
        if case .syncing = lanSync.status { return true }
        return false
    }
}
