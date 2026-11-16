import SwiftUI

/// 设置 › 终端。光标形状 / 闪烁与 Mac 同步、iOS 终端照读（`MTerminalHostView`，默认值在共享的
/// `TerminalCursorPreference`）；字体与字号固定只读；历史行数 / 选中即复制不接入 iOS
/// （理由见 `SettingsCatalog.syncedKeyExemptions`）。
struct SettingsTerminalSection: View {
    @AppStorage(DefaultsKey.terminalCursorShape)
    private var cursorShapeRaw: String = TerminalCursorPreference.defaultShape.rawValue
    @AppStorage(DefaultsKey.terminalCursorBlink)
    private var cursorBlink: Bool = TerminalCursorPreference.defaultBlink

    private var cursorShape: TerminalCursorShape { TerminalCursorPreference.shape(rawValue: cursorShapeRaw) }

    var body: some View {
        MInsetGroup(header: "终端") {
            MInsetRow(label: "字体", value: "系统等宽", valueMono: true)
            // 移动端终端字号随可用宽度自适应（9–13pt，见 TerminalSessionBody.adaptiveFontSize），
            // 不是固定 13pt——iPhone Duo 外屏 / 分屏更小、展开 / iPad 更大。
            MInsetRow(label: "字号", value: "随宽度自适应")
            MInsetRow(label: "光标形状",
                      trailing: AnyView(MMenu {
                          ForEach(TerminalCursorShape.allCases) { shape in
                              Button(shape.localizedLabel) { cursorShapeRaw = shape.rawValue }
                          }
                      } label: {
                          HStack(spacing: 4) {
                              Text(cursorShape.localizedLabel).font(M.sans(15)).foregroundStyle(M.text2)
                              MIcon(name: "chev-down", size: 11, color: M.text4)
                          }
                      }))
            MInsetRow(label: "闪烁",
                      trailing: AnyView(MSwitch(on: $cursorBlink)))
            // 键盘条 AI 面板里的启动命令 / 提示词 / 斜杠命令。只在本机，不跨设备同步。
            NavigationLink { TerminalPhrasesScreen() } label: {
                MInsetRow(label: "键盘条短语", sub: "启动命令、提示词、斜杠命令", chevron: true, last: true)
            }
            .buttonStyle(MRowStyle())
        }
    }
}
