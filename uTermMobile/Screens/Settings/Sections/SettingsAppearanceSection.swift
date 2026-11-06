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
                AccentPickerRow()
            }
            .padding(14)
        }
    }
}

/// 强调色选择（5 色，写 AccentState，全局即时重染）。
struct AccentPickerRow: View {
    @State private var selected: AccentColor = AccentState.shared.selected

    var body: some View {
        HStack(spacing: 4) {
            ForEach(AccentColor.allCases) { color in
                let c = color.base(dark: true).color()
                let on = selected == color
                Circle().fill(c)
                    .frame(width: 30, height: 30)
                    // 选中环：外圈一道正文色描边，中间隔开 3pt 卡片底。旧版是贴边白环，
                    // 日间白卡上完全看不出选中了哪一个。
                    .padding(3)
                    .overlay(Circle().strokeBorder(on ? M.text : .clear, lineWidth: 2))
                    .frame(width: M.minTarget, height: M.minTarget)   // 命中区 44pt
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.spring(duration: 0.25)) {
                            selected = color
                            AccentState.shared.selected = color
                        }
                    }
                    .accessibilityElement()
                    .accessibilityLabel(Text(color.label))
                    .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
            }
            Spacer()
        }
        .padding(.leading, -7)   // 让第一个色块的视觉左缘与上方「强调色」文字对齐
    }
}
