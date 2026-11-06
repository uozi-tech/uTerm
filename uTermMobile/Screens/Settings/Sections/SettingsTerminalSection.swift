import SwiftUI

/// 设置 › 终端。iOS 端终端外观固定，只作信息展示：光标形状 / 闪烁 / 历史行数 / 选中即复制
/// 这几项 Mac 设置不接入 iOS 终端（理由见 `SettingsCatalog.syncedKeyExemptions`）。
struct SettingsTerminalSection: View {
    var body: some View {
        MInsetGroup(header: "终端") {
            MInsetRow(label: "字体", value: "系统等宽", valueMono: true)
            // 移动端终端字号随可用宽度自适应（9–13pt，见 TerminalSessionBody.adaptiveFontSize），
            // 不是固定 13pt——iPhone Duo 外屏 / 分屏更小、展开 / iPad 更大。
            MInsetRow(label: "字号", value: "随宽度自适应")
            MInsetRow(label: "光标", value: "稳定块", last: true)
        }
    }
}
