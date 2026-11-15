import UDesignKit
import SwiftUI

/// 设置 › 外观：主题 + 强调色（与 Mac 同步）。
struct SettingsAppearanceSection: View {
    @AppStorage(DefaultsKey.appearancePreference)
    private var appearanceRaw: String = AppearancePreference.system.rawValue

    var body: some View {
        MInsetGroup(header: "外观") {
            VStack(alignment: .leading, spacing: 9) {
                Text("主题").font(M.sans(14)).foregroundStyle(M.text2)
                Picker("主题", selection: $appearanceRaw.rawValue(AppearancePreference.self, default: .system)) {
                    ForEach(AppearancePreference.allCases) { p in Text(p.localizedLabel).tag(p) }
                }
                .pickerStyle(.segmented)
            }
            .padding(14)
            .overlay(alignment: .bottom) { MRowDivider() }

            VStack(alignment: .leading, spacing: 11) {
                Text("强调色").font(M.sans(14)).foregroundStyle(M.text2)
                UDAccentSwatches(
                    selection: Binding(get: { AccentState.shared.selected },
                                       set: { AccentState.shared.selected = $0 }),
                    size: 30, spacing: 14)
            }
            // 色板只占自身宽度，不撑满就会被分组居中（旧版靠行尾 Spacer 撑开）。
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
        }
    }
}
