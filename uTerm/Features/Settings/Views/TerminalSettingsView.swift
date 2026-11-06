import UDesignKit
import SwiftUI

/// 设置 · 终端 tab。Spec 03 实现，后简化：终端/编辑器字体（系统等宽）与配色已不可
/// 自定义（VS Code 家族随外观），本页只保留 光标 / 历史 /
/// 选中即复制 + 预览。
///
/// 余下 @AppStorage 仍全部 live-update：TerminalHostView 观察同名 key
/// 触发 updateNSView 重 apply。
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
            SettingsPageHeader(title: "终端", subtitle: String(localized: "光标、回滚缓冲与退出时的行为"))

            SettingsGroup(title: "预览") {
                TerminalPreview(settings: currentSettings)
                    .padding(10)
            }
            SettingsGroup(title: "光标") {
                SettingsRow(label: "形状") {
                    UDSegmented(selection: cursorShapeBinding,
                                options: TerminalCursorShape.allCases.map { ($0, $0.localizedLabel) })
                }
                SettingsRow(label: "闪烁") {
                    UDToggle($cursorBlink)
                }
            }
            SettingsGroup(title: "行为") {
                SettingsRow(label: "历史行数",
                            hint: "保留在内存中的回滚缓冲区行数") {
                    SettingsNumberField(value: $scrollback, width: 96, suffix: String(localized: "行"))
                }
                SettingsRow(label: "选中即复制") {
                    UDToggle($copyOnSelect)
                }
            }
            SettingsGroup(title: "退出与重启",
                          footer: String(localized: "选择保留时，本机和 SSH 终端里的程序继续运行，下次打开 uTerm 时自动接回；崩溃和应用更新一律保留。保住局域网连接需要系统再授权一次（记在「uTerm 终端」名下），只影响之后新开的本机终端；SSH 标签总是保住。")) {
                SettingsRow(label: "退出 uTerm 时") {
                    UDSegmented(selection: $quitBehavior, options: [
                        (value: TerminalQuitPolicy.Behavior.ask.rawValue, label: String(localized: "询问")),
                        (value: TerminalQuitPolicy.Behavior.keep.rawValue, label: String(localized: "保留")),
                        (value: TerminalQuitPolicy.Behavior.end.rawValue, label: String(localized: "全部结束")),
                    ])
                }
                SettingsRow(label: "重启时保住本机终端的局域网连接",
                            hint: "比如在本机终端里 ssh 到局域网的机器") {
                    UDToggle($keepsLANConnections)
                }
            }
        }
    }
}
