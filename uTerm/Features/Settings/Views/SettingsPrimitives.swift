import UDesignKit
import SwiftUI

// macOS 设置窗的排版原语：分组卡片范式（对齐系统设置），配色全走 `UD.*`。
//
// - 页面坐在窗底 `UD.bg` 上（user 定：不要灰色页面底），每个分组一张与页面同底色、1pt `UD.border`
//   描边的卡片；卡片里不铺灰底。描边是这里唯一的分组边界，属于设计语言 v2 的描边保留例外。
// - 卡片里一行一项，行间 1pt `UD.border`，左侧缩进到文字起点（列表行缩进到图标之后）。
// - 组标题在卡片上方，长说明放卡片下方的脚注，行内说明只放一两句。
//
// 用法：
//     SettingsScroll {
//         SettingsPageHeader(title: "通用", subtitle: "启动与更新")
//         SettingsGroup(title: "启动", footer: "…") {
//             SettingsRow(label: "启动时") { … }
//             SettingsListRow(icon: "key", tint: UD.accent, title: "SSH 密钥", subtitle: "3 把") { … }
//         }
//     }

/// 卡片内各行之间分隔线的左缩进与是否显示，由行自己声明（`settingsDivider(inset:)`），分组读取。
extension ContainerValues {
    /// 这一行上方分隔线的左缩进（相对卡片左缘）。nil = 这一行上方不画分隔线。
    @Entry var settingsDividerInset: CGFloat? = SettingsMetrics.rowInset
}

extension View {
    /// 改这一行上方分隔线的左缩进；传 nil 不画（如紧跟在上一行之后的二维码展开区）。
    func settingsDivider(inset: CGFloat?) -> some View {
        containerValue(\.settingsDividerInset, inset)
    }

    /// 作为上一项的子项：整行右移一级，缩进处放一个「↳」记号（光缩进会像一块空白，
    /// 竖导轨又像画错的线），分隔线跟着缩进。
    func settingsNested() -> some View {
        padding(.leading, SettingsMetrics.nestedIndent)
            .overlay(alignment: .topLeading) {
                Image(systemName: "arrow.turn.down.right")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(UD.text4)
                    .frame(width: SettingsMetrics.nestedIndent, height: 18)
                    .padding(.top, 11)
                    .padding(.leading, SettingsMetrics.rowInset)
                    .accessibilityHidden(true)
            }
            .settingsDivider(inset: SettingsMetrics.rowInset + SettingsMetrics.nestedIndent)
    }
}

extension View {
    /// 设置窗的卡片底：与页面同底色，1pt `SettingsLine.card` 描边划出分组边界（不用灰底，user 定）。
    func settingsCard() -> some View {
        background(
            RoundedRectangle(cornerRadius: SettingsMetrics.cardRadius, style: .continuous)
                .fill(UD.bg)
                .overlay(RoundedRectangle(cornerRadius: SettingsMetrics.cardRadius, style: .continuous)
                    .strokeBorder(SettingsLine.card, lineWidth: 1))
        )
    }
}

/// 设置窗里的线。全局 `UD.border` 已随 uAppKit 1.9.4 调淡（user 反馈线太显眼），卡片描边直接用它，
/// 与窗口级的栏间线同一个值；卡片内的行间线再淡一档，只起分行提示，不参与层级。
enum SettingsLine {
    /// 卡片描边 = 全局描边。
    static let card = UD.border
    /// 卡片内行间线。
    static let row = UD.dyn(.white(0.065), .black(0.045))
}

/// 设置页的尺寸常量。
enum SettingsMetrics {
    /// 卡片内行的左右内边距（也是普通行分隔线的缩进）。
    static let rowInset: CGFloat = 14
    /// 子项缩进。
    static let nestedIndent: CGFloat = 24
    /// 列表行图标方块边长。
    static let listIcon: CGFloat = 28
    /// 列表行分隔线缩进到文字起点：内边距 + 图标 + 间距。
    static let listTextInset: CGFloat = rowInset + listIcon + 12
    /// 内容列最大宽：宽窗不把控件拉到天边。
    static let contentMaxWidth: CGFloat = 640
    static let cardRadius: CGFloat = 10
}

// MARK: - 页

/// 设置页容器：`UD.bg` 底、内容列 maxWidth 640 左对齐、顶部 24 / 左右 32 / 底 32，分组间距 24。
struct SettingsScroll<Content: View>: View {
    /// 设置窗口里是 UD.bg；嵌进欢迎窗口（整窗 UD.panel）时跟着换。
    var background: Color = UD.bg
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                content()
            }
            .frame(maxWidth: SettingsMetrics.contentMaxWidth, alignment: .leading)
            .padding(.top, 24)
            .padding(.horizontal, 32)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(background)
    }
}

/// 页头：20pt 标题 + 一句话说明这页管什么。
struct SettingsPageHeader: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(UD.text)
                .accessibilityAddTraits(.isHeader)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 12.5))
                    .foregroundStyle(UD.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 2)
        .padding(.bottom, -4)
    }
}

/// 分组卡片：标题在上、同底色 + 1pt 描边的圆角卡片、行间自动插分隔线、脚注在下。
///
/// 调用点照旧写 `SettingsGroup(title:) { SettingsRow… }`；`if` 不成立的行不占位也不多画分隔线
/// （按子视图拆分，见 `Group(subviews:)`）。
struct SettingsGroup<Content: View>: View {
    let title: String?
    var footer: String?
    @ViewBuilder let content: () -> Content

    init(title: String?, footer: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(UD.text)
                    .padding(.horizontal, 2)
                    .accessibilityAddTraits(.isHeader)
            }
            Group(subviews: content()) { subviews in
                if !subviews.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(subviews.enumerated()), id: \.element.id) { index, subview in
                            if index > 0, let inset = subview.containerValues.settingsDividerInset {
                                Rectangle()
                                    .fill(SettingsLine.row)
                                    .frame(height: 1)
                                    .padding(.leading, inset)
                            }
                            subview
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .settingsCard()
                }
            }
            if let footer {
                SettingsFootnote(footer)
            }
        }
    }
}

/// 卡片下方的脚注（11.5pt `UD.text3`）。
struct SettingsFootnote: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(UD.text3)
            .lineSpacing(1.5)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 行

/// 卡片行：左侧标签（可带一两句说明、可带图标），右侧控件垂直居中。最小高 44。
struct SettingsRow<Trailing: View>: View {
    /// hint 的排版：普通说明文字，或可选中的等宽文本（路径、地址这类要复制的值）。
    enum HintStyle {
        case text
        case monospaced
    }

    let label: String
    let hint: String?
    let icon: String?
    let hintStyle: HintStyle
    @ViewBuilder let trailing: () -> Trailing

    init(label: String, hint: String? = nil, icon: String? = nil, hintStyle: HintStyle = .text,
         @ViewBuilder trailing: @escaping () -> Trailing) {
        self.label = label
        self.hint = hint
        self.icon = icon
        self.hintStyle = hintStyle
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .center, spacing: icon == nil ? 16 : 12) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundStyle(UD.text2)
                    .frame(width: 20)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(label)
                    .font(.system(size: 13))
                    .foregroundStyle(UD.text)
                    .fixedSize(horizontal: false, vertical: true)
                if let hint {
                    hintText(hint)
                }
            }
            Spacer(minLength: 12)
            // 把行 label 关联到右侧控件——UDToggle / UDSegmented / Slider 等
            // 无内建 label，VoiceOver 借此念出「<标签> 开关 / 选择」而非孤立的「开/关」。
            // 右侧先拿到自己的理想宽度（layoutPriority），长说明再折行；否则「查看事件…」会被挤成竖排。
            trailing()
                .layoutPriority(1)
                .accessibilityElement(children: .contain)
                .accessibilityLabel(label)
        }
        .settingsRowPadding()
    }

    @ViewBuilder
    private func hintText(_ hint: String) -> some View {
        switch hintStyle {
        case .text:
            Text(hint)
                .font(.system(size: 11.5))
                .foregroundStyle(UD.text3)
                .lineSpacing(1.5)
                .fixedSize(horizontal: false, vertical: true)
        case .monospaced:
            Text(hint)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(UD.text3)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

extension View {
    /// 卡片行的统一内边距与最小高。
    func settingsRowPadding() -> some View {
        padding(.horizontal, SettingsMetrics.rowInset)
            .padding(.vertical, 8)
            .frame(minHeight: 44)
    }
}

/// 列表行：28pt 圆角方块图标（tint 14% 底 + tint 符号）、主副文案、右侧状态与动作。
/// 分隔线缩进到文字起点。用于设备、技能目标、管理窗口入口这类「一项一个对象」的列表。
struct SettingsListRow<Trailing: View>: View {
    let icon: SettingsListIcon
    let title: String
    let subtitle: String?
    var subtitleStyle: SettingsRow<EmptyView>.HintStyle = .text
    @ViewBuilder let trailing: () -> Trailing

    init(icon: String, tint: Color, title: String, subtitle: String? = nil,
         subtitleStyle: SettingsRow<EmptyView>.HintStyle = .text,
         @ViewBuilder trailing: @escaping () -> Trailing) {
        self.icon = .symbol(icon, tint)
        self.title = title
        self.subtitle = subtitle
        self.subtitleStyle = subtitleStyle
        self.trailing = trailing
    }

    init(monogram: String, tint: Color, title: String, subtitle: String? = nil,
         @ViewBuilder trailing: @escaping () -> Trailing) {
        self.icon = .monogram(monogram, tint)
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            icon
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(UD.text)
                    .lineLimit(1)
                if let subtitle {
                    switch subtitleStyle {
                    case .text:
                        Text(subtitle)
                            .font(.system(size: 11.5))
                            .foregroundStyle(UD.text3)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    case .monospaced:
                        Text(subtitle)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(UD.text3)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                }
            }
            Spacer(minLength: 12)
            // 右侧是按钮 / 菜单 / 开关，按自身宽度排，不让长副文案把「显示二维码」挤成竖排折行。
            trailing()
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityElement(children: .contain)
                .accessibilityLabel(title)
        }
        .padding(.horizontal, SettingsMetrics.rowInset)
        .padding(.vertical, 9)
        .frame(minHeight: 50)
        .settingsDivider(inset: SettingsMetrics.listTextInset)
    }
}

/// 列表行左侧的圆角方块：SF Symbol 或首字母。
enum SettingsListIcon: View {
    case symbol(String, Color)
    case monogram(String, Color)

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        switch self {
        case .symbol(let name, let tint):
            Image(systemName: name)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: SettingsMetrics.listIcon, height: SettingsMetrics.listIcon)
                .background(shape.fill(tint.opacity(0.14)))
                .accessibilityHidden(true)
        case .monogram(let text, let tint):
            Text(text)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(tint)
                .frame(width: SettingsMetrics.listIcon, height: SettingsMetrics.listIcon)
                .background(shape.fill(tint.opacity(0.14)))
                .accessibilityHidden(true)
        }
    }
}

/// 卡片内的空态：居中符号 + 一句话。
struct SettingsEmptyRow: View {
    let symbol: String
    let text: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(UD.text4)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(UD.text3)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, SettingsMetrics.rowInset)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, minHeight: 72)
        .accessibilityElement(children: .combine)
    }
}

/// 卡片内居中展开的块（二维码、预览之类）。上方不画分隔线时调用方再加 `.settingsDivider(inset: nil)`。
struct SettingsCenteredBlock<Content: View>: View {
    var caption: String?
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 10) {
            content()
            if let caption {
                Text(caption)
                    .font(.system(size: 11.5))
                    .foregroundStyle(UD.text3)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, SettingsMetrics.rowInset)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity)
    }
}

/// 设备列表的图标：机型（老版本没报机型就用名字）里带 iPad 的用 ipad，其余按 iPhone 画。
nonisolated func settingsDeviceSymbol(for name: String) -> String {
    name.localizedCaseInsensitiveContains("ipad") ? "ipad" : "iphone"
}

/// 配对过的设备的图标：Mac 按机型分笔记本 / 台式，其余按名字分 iPhone / iPad。
nonisolated func settingsDeviceSymbol(for peer: RemotePeer) -> String {
    let name = peer.model ?? peer.name
    guard peer.isMac else { return settingsDeviceSymbol(for: name) }
    return name.localizedCaseInsensitiveContains("MacBook") ? "laptopcomputer" : "desktopcomputer"
}

// MARK: - 状态与提示

/// 状态：符号（或圆点）+ 文字，12.5pt。各页不再各写一份 `HStack { Image; Text }`。
struct SettingsStatusLabel: View {
    let symbol: String?
    let color: Color
    let text: String

    init(symbol: String?, tone: SettingsTone, text: String) {
        self.symbol = symbol
        self.color = tone.color
        self.text = text
    }

    init(symbol: String?, color: Color, text: String) {
        self.symbol = symbol
        self.color = color
        self.text = text
    }

    var body: some View {
        HStack(spacing: 6) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 12))
                    .foregroundStyle(color)
            } else {
                Circle().fill(color).frame(width: 7, height: 7)
            }
            Text(text)
                .font(.system(size: 12.5))
                .foregroundStyle(UD.text2)
                .lineLimit(1)
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

/// 卡片里的一行提示（错误、待批准、未注册……）：带色调的符号 + 文字，占一行。
/// 替代各页散落的 `Text(error).foregroundStyle(UD.danger)`。
struct SettingsInlineNote: View {
    let tone: SettingsTone
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(tone.color)
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(tone == .muted || tone == .neutral ? UD.text3 : tone.color)
                .lineSpacing(1.5)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, SettingsMetrics.rowInset)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var symbol: String {
        switch tone {
        case .danger: return "xmark.octagon.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .success: return "checkmark.circle.fill"
        case .active, .neutral, .muted: return "info.circle"
        }
    }
}

// MARK: - 控件

/// 下拉选择：选项多或文案长时替代一排分段控件（下拉比一排灰段轻）。
struct SettingsPicker<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, label: String)]
    var menuWidth: CGFloat = 200

    private var currentLabel: String {
        options.first { $0.value == selection }?.label ?? ""
    }

    var body: some View {
        UDDropdown(anchor: .trailing) { open in
            HStack(spacing: 8) {
                Text(currentLabel)
                    .font(.system(size: 12.5))
                    .foregroundStyle(UD.text)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(UD.text3)
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(open ? UD.button2Hover : UD.button2))
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        } content: {
            UDMenu(width: menuWidth, items: options.map { option in
                UDMenuItem(label: option.label, active: option.value == selection) {
                    selection = option.value
                }
            })
        }
        .fixedSize()
        .accessibilityValue(currentLabel)
    }
}

/// 行尾的「更多」菜单：把次要 / 危险动作（移除、撤销、打开系统设置）收进去，不和普通按钮并排挤。
struct SettingsMoreMenu: View {
    let items: [UDMenuItem]
    var help: String = String(localized: "更多操作")

    var body: some View {
        UDDropdown(anchor: .trailing) { open in
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(open ? UD.text : UD.text2)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(open ? UD.button2Hover : UD.button2))
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        } content: {
            UDMenu(width: 200, items: items)
        }
        .fixedSize()
        .help(help)
        .accessibilityLabel(help)
    }
}

/// 设置行里的整数输入框。外观对齐 DesignKit 输入框，但改用语义色 token（Settings
/// 窗口随全局浅 / 深外观变化），focus 时加 accent 描边。供需要精确数值、不便用滑块
/// 的设置项直接键入。`minValue` 在提交时钳下界（默认 0），`suffix` 可在框右侧附单位。
struct SettingsNumberField: View {
    @Binding var value: Int
    var width: CGFloat = 80
    var minValue: Int = 0
    var maxValue: Int = .max
    var suffix: String? = nil

    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            TextField("", value: Binding(
                get: { value },
                set: { value = min(maxValue, max(minValue, $0)) }
            ), format: .number)
                .textFieldStyle(.plain)
                .focused($focused)
                .multilineTextAlignment(.trailing)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(UD.text)
                .padding(.horizontal, 10)
                .frame(width: width, height: 28)
                .background(RoundedRectangle(cornerRadius: 7).fill(UD.inputBg))
                .overlay(RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(focused ? UD.accent : .clear, lineWidth: 1))
                .animation(.easeOut(duration: 0.15), value: focused)
                .accessibilityValue(suffix.map { "\(value) \($0)" } ?? "\(value)")
            if let suffix {
                Text(suffix)
                    .font(.system(size: 12.5))
                    .foregroundStyle(UD.text3)
            }
        }
    }
}

extension SettingsTone {
    /// 共享状态色调在 macOS 设置页上的颜色。
    var color: Color {
        switch self {
        case .muted:   return UD.text3
        case .neutral: return UD.text2
        case .active:  return UD.accent
        case .warning: return UD.caution
        case .success: return UD.success
        case .danger:  return UD.danger
        }
    }
}
