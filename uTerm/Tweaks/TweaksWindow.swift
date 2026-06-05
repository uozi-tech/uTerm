#if DEBUG
import SwiftUI

/// Tweaks 调试窗口（仅 DEBUG）。复用 Settings 列表原语 + 自绘扁平 chrome，
/// 观感与 Welcome / Settings 一致。写入 `TweaksModel.shared`，欢迎页即时联动。
struct TweaksWindow: View {
    @Bindable private var tweaks = TweaksModel.shared

    var body: some View {
        VStack(spacing: 0) {
            TweaksTitleBar()
            SettingsScroll {
                SettingsGroup(title: "Welcome 列表") {
                    SettingsRow(label: "数据来源",
                                hint: "覆盖欢迎页列表：真实数据 / 强制空态 / 强制 Mock。") {
                        UDSegmented(selection: $tweaks.welcomeSource, options: [
                            (value: WelcomeSource.real,  label: "真实"),
                            (value: WelcomeSource.empty, label: "空态"),
                            (value: WelcomeSource.mock,  label: "Mock"),
                        ])
                    }
                    SettingsRow(label: "服务器数量", hint: "0–50，超出自动钳到 50。") {
                        SettingsNumberField(value: $tweaks.serverCount, minValue: 0, suffix: "台")
                    }
                    SettingsRow(label: "分组数量", hint: "0–6，0 表示全部未分组。") {
                        SettingsNumberField(value: $tweaks.groupCount, minValue: 0)
                    }
                    SettingsRow(label: "置顶数量", hint: "前 N 条置顶，点亮侧栏「置顶」分区。") {
                        SettingsNumberField(value: $tweaks.pinnedCount, minValue: 0)
                    }
                    SettingsRow(label: "最近数量",
                                hint: "前 N 条带「上次连接」时间，点亮侧栏「最近」分区。") {
                        SettingsNumberField(value: $tweaks.recentCount, minValue: 0)
                    }
                    SettingsRow(label: "名称样式",
                                hint: "正常 / 超长（测截断换行）/ 混合极端值。") {
                        UDSegmented(selection: $tweaks.nameStyle, options: [
                            (value: MockNameStyle.normal, label: "正常"),
                            (value: MockNameStyle.long,   label: "超长"),
                            (value: MockNameStyle.mixed,  label: "混合"),
                        ])
                    }
                }
            }
        }
        .frame(minWidth: 460, minHeight: 520)
        .ignoresSafeArea(.container, edges: .top)
        .background(UD.bg)
        .background(WorkspaceWindowChrome(serverName: "Tweaks"))
        .disablesInitialAutoFocus()
    }
}

/// Tweaks 窗口自绘扁平标题栏（对齐 `WelcomeTitleBar`：36pt、让位红绿灯、底部 1px 描边）。
private struct TweaksTitleBar: View {
    var body: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: 84)
            Text("Tweaks")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(UD.text2)
            Spacer()
        }
        .frame(height: 36)
        .frame(maxWidth: .infinity)
        .background(WindowDragHandle())
        .overlay(alignment: .bottom) {
            Rectangle().fill(UD.border).frame(height: 1)
        }
    }
}

/// 仅 DEBUG 的顶部「Debug」菜单。挂在 Tweaks Scene 上即全局注册。
struct DebugCommands: Commands {
    var body: some Commands {
        CommandMenu("Debug") {
            OpenTweaksButton()
        }
    }
}

private struct OpenTweaksButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Tweaks…") { openWindow(id: "tweaks") }
            .keyboardShortcut("t", modifiers: [.command, .control])
    }
}
#endif
