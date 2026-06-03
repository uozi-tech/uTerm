import SwiftUI

/// macOS Settings 窗口（⌘,）—— 自定义 tab 壳。
///
/// 不用原生 `TabView` 的 preferences 工具栏（大图标叠标签、居中），改用设计稿
/// `settings.jsx` 的窗口内 tab 条：图标 + 文字横排、左对齐、选中态微底 pill。
/// 窗口标题栏（红绿灯 + 居中标题）仍由系统原生 chrome 提供。
struct SettingsView: View {
    @State private var tab: SettingsTab = .general

    var body: some View {
        VStack(spacing: 0) {
            SettingsTabStrip(selection: $tab)

            // 内容区
            Group {
                switch tab {
                case .general:   GeneralSettingsView()
                case .providers: ProvidersSettingsView()
                case .terminal:  TerminalSettingsView()
                case .advanced:  AdvancedSettingsView()
                case .about:     AboutSettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 720, height: 480)
    }
}

/// 设置 tab 标识。`label` / `symbol` 对应设计稿 `settings.jsx` 的 tab 条。
enum SettingsTab: String, CaseIterable, Identifiable {
    case general, providers, terminal, advanced, about

    var id: String { rawValue }

    var label: String {
        switch self {
        case .general:   return "通用"
        case .providers: return "AI 服务商"
        case .terminal:  return "终端"
        case .advanced:  return "高级"
        case .about:     return "关于"
        }
    }

    var symbol: String {
        switch self {
        case .general:   return "gearshape"
        case .providers: return "sparkles"
        case .terminal:  return "terminal"
        case .advanced:  return "slider.horizontal.3"
        case .about:     return "info.circle"
        }
    }
}

/// 设计稿 tab 条：高 44、左对齐、tab 间距 4、底部 1px 描边。
/// 每个 tab：padding 6×12、圆角 7、图标 + 文字横排（间距 7）、12.5pt；
/// 选中 = 微底 + 主文本色，未选 = 次要文本色。
private struct SettingsTabStrip: View {
    @Binding var selection: SettingsTab

    var body: some View {
        HStack(spacing: 4) {
            ForEach(SettingsTab.allCases) { item in
                tabButton(item)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(AppTheme.Palette.border)
                .frame(height: 1)
        }
    }

    @ViewBuilder
    private func tabButton(_ item: SettingsTab) -> some View {
        let isOn = item == selection
        Button {
            selection = item
        } label: {
            HStack(spacing: 7) {
                Image(systemName: item.symbol)
                    .font(.system(size: 12))
                Text(item.label)
                    .font(.system(size: 12.5))
            }
            .foregroundStyle(isOn ? AppTheme.Palette.textPrimary : AppTheme.Palette.textSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7).fill(isOn ? Color.primary.opacity(0.06) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
