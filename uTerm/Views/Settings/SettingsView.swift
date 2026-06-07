import SwiftUI

/// macOS Settings 窗口（⌘,）—— 自定义 tab 壳。
///
/// 不用原生 `TabView` 的 preferences 工具栏（大图标叠标签、居中），改用设计稿
/// `settings.jsx` 的窗口内 tab 条：图标 + 文字横排、左对齐、选中态微底 pill。
/// 窗口标题栏（红绿灯 + 居中标题）仍由系统原生 chrome 提供。
struct SettingsView: View {
    @AppStorage(SettingsTabSelection.key) private var selectedTab = SettingsTab.general.rawValue

    private var tab: SettingsTab {
        SettingsTabSelection.tab(from: selectedTab)
    }

    private var tabBinding: Binding<SettingsTab> {
        Binding {
            SettingsTabSelection.tab(from: selectedTab)
        } set: { newValue in
            selectedTab = newValue.rawValue
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            SettingsTitleBar()
            SettingsTabStrip(selection: tabBinding)

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
        // 用 minHeight（而非固定 height）让内容**铺满整窗**——与 Welcome / Keys 一致。
        // 固定 height:480 + .ignoresSafeArea(.top) 会把内容上提、底部空出一条未覆盖区，
        // 露出窗口默认（浅色）底，短内容的「通用」tab 上显成「底部 footer」。铺满后
        // 该条由 UD.bg 覆盖消失。窗口初始尺寸由 Scene 的 .defaultSize 决定。
        .frame(minWidth: 720, minHeight: 480)
        // 设计稿 settings.jsx：整窗内容坐在 `U.bg` 上（深 #101012）。其余主窗
        // （工作区 / SFTP / 表单 / 密钥）皆已 .background(UD.bg)，设置窗补齐对齐。
        // 自绘扁平 chrome：透明系统标题栏 + full-size content，红绿灯让位由 SettingsTitleBar
        // 预留。取代原「系统原生标题栏」——后者暗夜下是更浅的系统灰，与设计稿 #101012 不符。
        .ignoresSafeArea(.container, edges: .top)
        .background(UD.bg)
        .background(WorkspaceWindowChrome(serverName: "设置"))
    }
}

/// 设置窗口自绘扁平标题栏（对齐其它窗口的自绘 chrome）：左侧让位窗口红绿灯（~68pt），
/// 居中 "设置"。38px 扁平 UD.panel 条 + 底部 1px 描边。替代 macOS 系统标题栏。
private struct SettingsTitleBar: View {
    var body: some View {
        ZStack {
            Text("设置")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(UD.text)
            HStack(spacing: 0) {
                Color.clear.frame(width: 68)   // 让位窗口红绿灯
                Spacer()
            }
            .padding(.horizontal, 8)
        }
        .frame(height: 38)
        .frame(maxWidth: .infinity)
        .background(WindowDragHandle())
        .overlay(alignment: .bottom) {
            Rectangle().fill(UD.border).frame(height: 1)
        }
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

nonisolated enum SettingsTabSelection {
    static let key = "settingsTabSelection"
    static let aboutMenuTarget = SettingsTab.about.rawValue

    static func tab(from rawValue: String?) -> SettingsTab {
        rawValue.flatMap(SettingsTab.init(rawValue:)) ?? .general
    }
}

/// 设置窗口标识。改用普通 `Window`（而非 macOS `Settings`/Preferences 场景）打开，
/// 原因：Preferences 场景不可靠地忽略 `.windowStyle(.hiddenTitleBar)`，始终画系统标题栏，
/// 自绘 chrome（`SettingsTitleBar` + `WorkspaceWindowChrome`）盖不住。改普通 Window 后
/// 与 Welcome / Keys / Groups 同构，chrome 才能真正接管。⌘, 由 `.appSettings` 命令组重绑。
nonisolated enum SettingsWindow {
    static let id = "settings"
}

/// 设计稿 tab 条：高 44、左对齐、tab 间距 4、底部 1px 描边。
/// 每个 tab：padding 6×12、圆角 7、图标 + 文字横排（间距 7）、12.5pt；
/// 选中 = 微底 + 主文本色，未选 = 次要文本色。
private struct SettingsTabStrip: View {
    @Binding var selection: SettingsTab
    @FocusState private var focusedTab: SettingsTab?

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
                .fill(UD.border)
                .frame(height: 1)
        }
    }

    @ViewBuilder
    private func tabButton(_ item: SettingsTab) -> some View {
        let isOn = item == selection
        let focused = focusedTab == item
        Button {
            selection = item
        } label: {
            HStack(spacing: 7) {
                Image(systemName: item.symbol)
                    .font(.system(size: 12))
                Text(item.label)
                    .font(.system(size: 12.5))
            }
            .foregroundStyle(isOn ? UD.text : UD.text2)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7).fill(isOn ? UD.accentSoft : Color.clear))   // 选中 = accent-soft（去黑 6% 灰底）
            // 键盘焦点环：focusable 时画 accent 描边（VoiceOver / Tab 导航可见）。
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(UD.accent, lineWidth: focused ? 2 : 0)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable()
        .focused($focusedTab, equals: item)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }
}
