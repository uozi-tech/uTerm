import UDesignKit
import SwiftUI

/// 设置 · 终端 tab。Spec 03 实现，后简化：终端/编辑器字体（系统等宽）与配色已不可
/// 自定义（VS Code 家族随外观），本页只保留 光标 / 历史 /
/// 选中即复制 + 预览。
///
/// 余下 @AppStorage 仍全部 live-update：`GhosttyHostView` 观察同名 key
/// 触发 updateNSView 重新应用（`GhosttyTerminalBridge.apply(settings:)`）。
struct TerminalSettingsView: View {
    @AppStorage(DefaultsKey.terminalCursorShape)  private var cursorShapeRaw: String = TerminalCursorShape.block.rawValue
    @AppStorage(DefaultsKey.terminalCursorBlink)  private var cursorBlink: Bool = false
    @AppStorage(DefaultsKey.terminalScrollback)   private var scrollback: Int = 3_000
    @AppStorage(DefaultsKey.terminalCopyOnSelect) private var copyOnSelect: Bool = false

    private var cursorShapeBinding: Binding<TerminalCursorShape> {
        $cursorShapeRaw.rawValue(TerminalCursorShape.self, default: .block)
    }

    private var currentSettings: TerminalSettings {
        TerminalSettings(
            cursorShape: cursorShapeBinding.wrappedValue,
            cursorBlink: cursorBlink,
            scrollback: scrollback,
            copyOnSelect: copyOnSelect
        )
    }

    @AppStorage(TerminalQuitPolicy.behaviorKey) private var quitBehavior = TerminalQuitPolicy.Behavior.ask.rawValue
    @AppStorage(LocalShellNetworkPolicy.key) private var keepsLANConnections = false

    var body: some View {
        SettingsScroll {
            SettingsPageHeader(title: String(localized: "终端", comment: "设置分区"), subtitle: String(localized: "光标、回滚缓冲与退出时的行为"))

            SettingsGroup(title: String(localized: "预览", comment: "设置分组：终端外观预览")) {
                TerminalPreview(settings: currentSettings)
                    .padding(10)
            }
            SettingsGroup(title: String(localized: "光标", comment: "设置分组：终端光标")) {
                SettingsRow(label: String(localized: "形状", comment: "光标形状")) {
                    UDSegmented(selection: cursorShapeBinding,
                                options: TerminalCursorShape.allCases.map { ($0, $0.localizedLabel) })
                }
                SettingsRow(label: String(localized: "闪烁", comment: "光标闪烁")) {
                    UDToggle($cursorBlink)
                }
            }
            SettingsGroup(title: String(localized: "行为", comment: "设置分组：终端行为")) {
                SettingsRow(label: String(localized: "历史行数", comment: "终端回滚缓冲区行数"),
                            hint: String(localized: "保留在内存中的回滚缓冲区行数")) {
                    SettingsNumberField(value: $scrollback, width: 96, suffix: String(localized: "行"))
                }
                SettingsRow(label: String(localized: "选中即拷贝")) {
                    UDToggle($copyOnSelect)
                }
            }
            SettingsGroup(title: String(localized: "退出与重启"),
                          footer: String(localized: "选择保留时，本机和 SSH 终端里的程序继续运行，下次打开 uTerm 时自动恢复；崩溃和应用更新一律保留。保持局域网连接需要系统再授权一次（记在「uTerm 终端」名下），只影响之后新开的本机终端；SSH 标签页总会保留。")) {
                SettingsRow(label: String(localized: "退出 uTerm 时")) {
                    UDSegmented(selection: $quitBehavior, options: [
                        (value: TerminalQuitPolicy.Behavior.ask.rawValue, label: String(localized: "询问")),
                        (value: TerminalQuitPolicy.Behavior.keep.rawValue, label: String(localized: "保留")),
                        (value: TerminalQuitPolicy.Behavior.end.rawValue, label: String(localized: "全部结束")),
                    ])
                }
                SettingsRow(label: String(localized: "重启时保持本机终端的局域网连接"),
                            hint: String(localized: "比如在本机终端里 ssh 到局域网的机器")) {
                    UDToggle($keepsLANConnections)
                }
            }
        }
    }
}
