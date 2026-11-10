import SwiftUI

/// 设置 › 同步：iCloud 状态 / 同步诊断 / 会话保留，以及局域网接收（`LANSyncSettingsSection`）。
/// 状态图标与色调、保留档位与文案都在共享层（`SyncStatusPresentation` / `ChatRetentionPresentation`），
/// 与 Mac 的「同步」页同一份。
struct SettingsSyncSection: View {
    let cloudStatus: CloudKitSyncStatus
    let diagnosticsSubtitle: String
    let showDiagnostics: () -> Void

    @AppStorage(ChatHistoryStore.retentionDaysKey)
    private var chatRetentionDays = ChatHistoryStore.defaultRetentionDays
    @Environment(\.mAccent) private var accent

    var body: some View {
        MInsetGroup(header: "同步", footer: ChatRetentionPresentation.footer(for: chatRetentionDays, platform: .iOS)) {
            MInsetRow(icon: "icloud", label: "iCloud 同步", trailing: AnyView(cloudBadge))
            MInsetRow(icon: "diag", label: "同步诊断", sub: diagnosticsSubtitle,
                      chevron: true, onTap: showDiagnostics)
            ChatRetentionRow(days: $chatRetentionDays, last: true)
        }
        LANSyncSettingsSection()
    }

    private var cloudBadge: some View {
        let cloud = SyncStatusPresentation.cloud(cloudStatus)
        return HStack(spacing: 5) {
            Image(systemName: cloud.symbol)
                .font(.system(size: 13))
                .foregroundStyle(cloud.tone.mColor(accent: accent))
            Text(cloudStatus.label).font(M.sans(14)).foregroundStyle(M.text3)
        }
    }
}

/// 「会话保留」行：右侧预设档菜单。0 = 不清理。手机上不弹数字键盘，Mac 上填过的非预设值照样显示。
struct ChatRetentionRow: View {
    @Binding var days: Int
    var last = false

    var body: some View {
        MInsetRow(icon: "clock", label: "AI 对话保留", last: last,
                  trailing: AnyView(
                      MMenu {
                          ForEach(ChatRetentionPresentation.options, id: \.days) { option in
                              Button(option.label) { days = option.days }
                          }
                      } label: {
                          HStack(spacing: 4) {
                              Text(ChatRetentionPresentation.label(for: days))
                                  .font(M.sans(15)).foregroundStyle(M.text2)
                              MIcon(name: "chev-down", size: 11, color: M.text4)
                          }
                      }))
    }
}
