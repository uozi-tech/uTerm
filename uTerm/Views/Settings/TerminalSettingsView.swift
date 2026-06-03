import SwiftUI

/// 设置 · 终端 tab。Spec 03 实现：字体 / 字号 / 行距 / 配色 / 光标 / 历史 / 选中即复制。
///
/// 8 个 @AppStorage 全部 live-update：TerminalHostView 观察同名 key
/// 触发 updateNSView 重 apply。
struct TerminalSettingsView: View {
    @AppStorage("terminalFontName")     private var fontName: String = "Menlo"
    @AppStorage("terminalFontSize")     private var fontSize: Double = 11
    @AppStorage("terminalLineHeight")   private var lineHeight: Double = 1.0
    @AppStorage("terminalColorScheme")  private var colorSchemeRaw: String = TerminalColorSchemeID.vscodeDark.rawValue
    @AppStorage("terminalCursorShape")  private var cursorShapeRaw: String = TerminalCursorShape.block.rawValue
    @AppStorage("terminalCursorBlink")  private var cursorBlink: Bool = false
    @AppStorage("terminalScrollback")   private var scrollback: Int = 3_000
    @AppStorage("terminalCopyOnSelect") private var copyOnSelect: Bool = false

    private var fontBinding: Binding<TerminalFont> {
        Binding(
            get: { TerminalFont(rawValue: fontName) ?? .menlo },
            set: { fontName = $0.rawValue }
        )
    }
    private var colorSchemeBinding: Binding<TerminalColorSchemeID> {
        Binding(
            get: { TerminalColorSchemeID(rawValue: colorSchemeRaw) ?? .vscodeDark },
            set: { colorSchemeRaw = $0.rawValue }
        )
    }
    private var cursorShapeBinding: Binding<TerminalCursorShape> {
        Binding(
            get: { TerminalCursorShape(rawValue: cursorShapeRaw) ?? .block },
            set: { cursorShapeRaw = $0.rawValue }
        )
    }

    private var currentSettings: TerminalSettings {
        TerminalSettings(
            fontName: fontName,
            fontSize: fontSize,
            lineHeight: lineHeight,
            colorSchemeID: colorSchemeBinding.wrappedValue,
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
            SettingsGroup(title: "字体") {
                SettingsRow(label: "字体") {
                    UDSegmented(selection: fontBinding,
                                options: TerminalFont.allCases.map { ($0, $0.displayName) })
                }
                SettingsRow(label: "字号") {
                    UDSlider(value: $fontSize, in: 10...20, step: 1, ticks: 11,
                             valueLabel: { "\(Int($0)) pt" })
                        .frame(width: 228)
                }
                SettingsRow(label: "行距") {
                    UDSlider(value: $lineHeight, in: 1.0...2.0, step: 0.05,
                             valueLabel: { String(format: "%.2f", $0) })
                        .frame(width: 228)
                }
            }
            SettingsGroup(title: "配色") {
                SchemeCardGrid(selection: colorSchemeBinding)
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
