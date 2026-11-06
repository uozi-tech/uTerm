import UDesignKit
import SwiftUI

/// macOS Settings 窗口（⌘,）—— 左侧栏 + 右详情。
///
/// 分区（`SettingsSection`）与 iOS 设置根页同一份信息架构；侧栏按三组排：
/// 通用 / 外观 / 终端，模型服务 … 命令行与技能，诊断 / 关于。组间留白，不显示分组标题。
struct SettingsView: View {
    @AppStorage(SettingsTabSelection.key) private var selectedTab = SettingsSection.general.rawValue

    /// 侧栏分组（自上而下）。每个 macOS 可用的分区恰好出现一次（`SettingsCatalogTests` 钉住）。
    static let sidebarGroups: [[SettingsSection]] = [
        [.general, .appearance, .terminal],
        [.providers, .connection, .security, .sync, .remote, .cli],
        [.diagnostics, .about],
    ]

    /// macOS 设置窗里有页面的分区，按侧栏顺序。
    static let sections: [SettingsSection] = sidebarGroups.flatMap { $0 }

    /// 记住的分区不在本窗（iOS 才有的分区）时回到「通用」。
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

    /// 分区 → 页面。
    @ViewBuilder
    static func page(for section: SettingsSection) -> some View {
        switch section {
        case .general:     GeneralSettingsView()
        case .appearance:  AppearanceSettingsView()
        case .terminal:    TerminalSettingsView()
        case .providers:   ProvidersSettingsView()
        case .connection:  ConnectionSettingsView()
        case .security:    SecuritySettingsView()
        case .sync:        SyncSettingsView()
        case .remote:      RemoteControlSettingsView()
        case .cli:         CLISettingsView()
        case .diagnostics: DiagnosticsSettingsView()
        case .about:       AboutSettingsView()
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            SettingsTitleBar()
            HStack(spacing: 0) {
                SettingsSidebar(selection: tabBinding)
                // 与 ProvidersSettingsView / KeyManagerView 同：UD.border 实色竖线区隔，不用系统 Divider。
                Rectangle().fill(UD.border).frame(width: 1)
                // 内容区。左上对齐并裁剪：任何页面再溢出也只裁右边，侧栏永远不会被挤出窗口
                // （曾经「模型服务」的固定宽输入框在 780 宽时把整个 HStack 撑宽、居中，侧栏左侧被裁掉约 20pt）。
                Self.page(for: tab)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(UD.bg)
                    .clipped()
            }
        }
        // 用 minHeight（而非固定 height）让内容**铺满整窗**——与 Welcome / Keys 一致。
        // 固定 height:480 + .ignoresSafeArea(.top) 会把内容上提、底部空出一条未覆盖区，
        // 露出窗口默认（浅色）底，短内容的「通用」tab 上显成「底部 footer」。铺满后
        // 该条由 UD.bg 覆盖消失。窗口初始尺寸由 Scene 的 .defaultSize 决定。
        .frame(minWidth: 880, minHeight: 600)
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

/// 设置侧栏：宽 200、坐在 UD.bg 上；行 = 22pt 彩色圆角方块图标 + 13pt 文字，行高 32、圆角 7；
/// 选中 = accent 淡底 + accentInk，hover = UD.rowHover。组间 12pt 留白，不显示分组标题。
private struct SettingsSidebar: View {
    @Binding var selection: SettingsSection

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(SettingsView.sidebarGroups.enumerated()), id: \.offset) { _, group in
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(group) { item in
                            SettingsSidebarRow(item: item, isOn: item == selection) {
                                selection = item
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 12)
        }
        .frame(width: 200)
        .background(UD.bg)
    }
}

private struct SettingsSidebarRow: View {
    let item: SettingsSection
    let isOn: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                SettingsSidebarIcon(section: item, isOn: isOn)
                Text(item.title)
                    .font(.system(size: 13, weight: isOn ? .medium : .regular))
                    .foregroundStyle(isOn ? UD.accentInk : UD.text)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .frame(height: 32)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isOn ? UD.accentSoft : (hovering ? UD.rowHover : Color.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        // 原生 Button 本就键盘可达，不再叠 .focusable()（会多生一个可聚焦元素 + 系统焦点环）。
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }
}

/// 侧栏图标：单色 SF Symbol，选中随文字走 accentInk，未选中 `UD.text2`；不用彩色方块（user 定）。
private struct SettingsSidebarIcon: View {
    let section: SettingsSection
    let isOn: Bool

    var body: some View {
        Image(systemName: section.symbol)
            .font(.system(size: 14, weight: .regular))
            .foregroundStyle(isOn ? UD.accentInk : UD.text2)
            .frame(width: 22, height: 22)
            .accessibilityHidden(true)
    }
}
