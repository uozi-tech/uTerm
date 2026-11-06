import SwiftUI

/// 设置 › 历史：AI 会话保留窗口。与 macOS 共用 key，可经 iCloud KVS / 局域网同步。
/// 用预设菜单而不是数字输入（档位与文案在共享的 `ChatRetentionPresentation`）。0 = 不清理。
struct SettingsHistorySection: View {
    @AppStorage(ChatHistoryStore.retentionDaysKey)
    private var chatRetentionDays = ChatHistoryStore.defaultRetentionDays

    var body: some View {
        MInsetGroup(header: "历史", footer: ChatRetentionPresentation.footer(for: chatRetentionDays, platform: .iOS)) {
            ChatRetentionRow(days: $chatRetentionDays, last: true)
        }
    }
}

/// 「会话保留」行：右侧预设档菜单。
struct ChatRetentionRow: View {
    @Binding var days: Int
    var last = false

    var body: some View {
        MInsetRow(icon: "clock", label: "会话保留", last: last,
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
