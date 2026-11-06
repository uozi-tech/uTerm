import UDesignKit
import SwiftUI

/// macOS Settings 窗口（⌘,）—— 自定义 tab 壳。
///
/// 不用原生 `TabView` 的 preferences 工具栏（大图标叠标签、居中），改用设计稿
/// `settings.jsx` 的窗口内 tab 条：图标 + 文字横排、左对齐、选中态微底 pill。
/// 窗口标题栏（红绿灯 + 居中标题）仍由系统原生 chrome 提供。
struct SettingsView: View {
    @AppStorage(SettingsTabSelection.key) private var selectedTab = SettingsSection.general.rawValue

    /// macOS 设置窗里有页面的分区，按 tab 条顺序。
    static let sections: [SettingsSection] = [.general, .providers, .terminal, .remote, .connection, .cli, .about]

    /// 记住的分区不在本窗（旧版本写的、或命令面板写了 iOS 才有的分区）时回到「通用」。
    private var tab: SettingsSection {
        let stored = SettingsTabSelection.tab(from: selectedTab)
        return Self.sections.contains(stored) ? stored : .general
    }

    private var tabBinding: Binding<SettingsSection> {
        Binding {
            tab
        } set: { newValue in
            selectedTab = newValue.rawValue
        }
    }

    /// 分区 → 页面。不在本窗的分区（`sections` 之外）给空视图。
    @ViewBuilder
    static func page(for section: SettingsSection) -> some View {
        switch section {
        case .general:    GeneralSettingsView()
        case .providers:  ProvidersSettingsView()
        case .terminal:   TerminalSettingsView()
        case .remote:     RemoteControlSettingsView()
        case .connection: AdvancedSettingsView()
        case .cli:        CLISettingsView()
        case .about:      AboutSettingsView()
        case .appearance, .security, .sync, .diagnostics:
            EmptyView()
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            SettingsTitleBar()
            SettingsTabStrip(selection: tabBinding)

            // 内容区
            Self.page(for: tab)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // 用 minHeight（而非固定 height）让内容**铺满整窗**——与 Welcome / Keys 一致。
        // 固定 height:480 + .ignoresSafeArea(.top) 会把内容上提、底部空出一条未覆盖区，
        // 露出窗口默认（浅色）底，短内容的「通用」tab 上显成「底部 footer」。铺满后
        // 该条由 UD.bg 覆盖消失。窗口初始尺寸由 Scene 的 .defaultSize 决定。
        .frame(minWidth: 720, minHeight: 480)
        // 设计稿 settings.jsx：整窗内容坐在 `U.bg` 上（深 #000000）。其余主窗
        // （工作区 / SFTP / 表单 / 密钥）皆已 .background(UD.bg)，设置窗补齐对齐。
        // 自绘扁平 chrome：透明系统标题栏 + full-size content，红绿灯让位由 SettingsTitleBar
        // 预留。取代原「系统原生标题栏」——后者暗夜下是更浅的系统灰，与设计稿底色 UD.bg 不符。
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
                // 纯展示，不参与命中测试：否则会截走标题栏空白处的双击（缩放）/ 拖动（见 WindowDragHandle）。
                .allowsHitTesting(false)
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

/// 设置窗口标识。改用普通 `Window`（而非 macOS `Settings`/Preferences 场景）打开，
/// 原因：Preferences 场景不可靠地忽略 `.windowStyle(.hiddenTitleBar)`，始终画系统标题栏，
/// 自绘 chrome（`SettingsTitleBar` + `WorkspaceWindowChrome`）盖不住。改普通 Window 后
/// 与 Welcome / Keys / Groups 同构，chrome 才能真正接管。⌘, 由 `.appSettings` 命令组重绑。
nonisolated enum SettingsWindow {
    static let id = "settings"
}

/// 设计稿 tab 条：高 44、左对齐、tab 间距 4、底部 1px 描边。
/// 每个 tab：padding 6×12、圆角 7、图标 + 文字横排（间距 7）、12.5pt；
/// 选中 = accent 淡底 + accentInk（驾驶舱 pill），未选 = 次要文本色。
private struct SettingsTabStrip: View {
    @Binding var selection: SettingsSection

    var body: some View {
        HStack(spacing: 4) {
            ForEach(SettingsView.sections) { item in
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
    private func tabButton(_ item: SettingsSection) -> some View {
        let isOn = item == selection
        Button {
            selection = item
        } label: {
            HStack(spacing: 7) {
                Image(systemName: item.symbol)
                    .font(.system(size: 12))
                Text(item.title)
                    .font(.system(size: 12.5))
            }
            .foregroundStyle(isOn ? UD.accentInk : UD.text2)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7).fill(isOn ? UD.accentSoft : Color.clear))   // 选中 = accent-soft（去黑 6% 灰底）
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // 原设计无任何 tab 描边：选中态仅靠 accentSoft 填充。原生 Button 本就键盘可达，
        // 不再叠 .focusable()（会多生一个可聚焦元素 + macOS 系统焦点环 → 双层 border）。
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }
}
