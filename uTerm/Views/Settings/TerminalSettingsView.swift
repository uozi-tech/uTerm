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
                    Picker("", selection: fontBinding) {
                        ForEach(TerminalFont.allCases) { f in
                            Text(f.displayName).tag(f)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 280)
                }
                SettingsRow(label: "字号") {
                    HStack(spacing: 12) {
                        Slider(value: $fontSize, in: 10...20, step: 1)
                            .frame(width: 160)
                        Text("\(Int(fontSize)) pt")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(AppTheme.Palette.textMuted)
                            .frame(width: 56, alignment: .trailing)
                    }
                }
                SettingsRow(label: "行距") {
                    HStack(spacing: 12) {
                        Slider(value: $lineHeight, in: 1.0...2.0, step: 0.05)
                            .frame(width: 160)
                        Text(String(format: "%.2f", lineHeight))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(AppTheme.Palette.textMuted)
                            .frame(width: 56, alignment: .trailing)
                    }
                }
            }
            SettingsGroup(title: "配色") {
                SchemeCardGrid(selection: colorSchemeBinding)
            }
            SettingsGroup(title: "光标") {
                SettingsRow(label: "形状") {
                    Picker("", selection: cursorShapeBinding) {
                        ForEach(TerminalCursorShape.allCases) { s in
                            Text(s.localizedLabel).tag(s)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 280)
                }
                SettingsRow(label: "闪烁") {
                    Toggle("", isOn: $cursorBlink).labelsHidden().toggleStyle(.switch)
                }
            }
            SettingsGroup(title: "行为") {
                SettingsRow(label: "历史行数",
                            hint: "保留在内存中的回滚缓冲区行数") {
                    HStack(spacing: 12) {
                        Slider(value: Binding(
                            get: { Double(scrollback) },
                            set: { scrollback = Int($0) }
                        ), in: 1000...100000, step: 1000)
                            .frame(width: 160)
                        Text("\(scrollback)")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(AppTheme.Palette.textMuted)
                            .frame(width: 56, alignment: .trailing)
                    }
                }
                SettingsRow(label: "选中即复制") {
                    Toggle("", isOn: $copyOnSelect).labelsHidden().toggleStyle(.switch)
                }
            }
        }
    }
}
