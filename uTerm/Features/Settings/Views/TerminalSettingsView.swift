import UDesignKit
import SwiftUI

/// 设置 · 终端 tab。Spec 03 实现，后简化：终端/编辑器字体（系统等宽）与配色已不可
/// 自定义（VS Code 家族随外观），本页只保留 光标 / 历史 /
/// 选中即复制 + 预览。
///
/// 余下 @AppStorage 仍全部 live-update：TerminalHostView 观察同名 key
/// 触发 updateNSView 重 apply。
struct TerminalSettingsView: View {
    @AppStorage("terminalCursorShape")  private var cursorShapeRaw: String = TerminalCursorShape.block.rawValue
    @AppStorage("terminalCursorBlink")  private var cursorBlink: Bool = false
    @AppStorage("terminalScrollback")   private var scrollback: Int = 3_000
    @AppStorage("terminalCopyOnSelect") private var copyOnSelect: Bool = false

    private var cursorShapeBinding: Binding<TerminalCursorShape> {
        Binding(
            get: { TerminalCursorShape(rawValue: cursorShapeRaw) ?? .block },
            set: { cursorShapeRaw = $0.rawValue }
        )
    }

    private var currentSettings: TerminalSettings {
        TerminalSettings(
            cursorShape: cursorShapeBinding.wrappedValue,
            cursorBlink: cursorBlink,
            scrollback: scrollback,
            copyOnSelect: copyOnSelect
        )
    }

    var body: some View {
        SettingsScroll {
            SettingsGroup(title: "预览") {
                TerminalPreview(settings: currentSettings)
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
                    SettingsNumberField(value: $scrollback)
                }
                SettingsRow(label: "选中即复制") {
                    UDToggle($copyOnSelect)
                }
            }
        }
    }
}
