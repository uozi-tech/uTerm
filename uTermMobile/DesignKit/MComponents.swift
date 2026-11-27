import UDesignKit
import SwiftUI

// MARK: - 按钮 MBtn

enum MBtnKind { case primary, tinted, danger, dangerTint, secondary }

/// 主/次按钮，对齐设计稿 `m-kit` 的 `MBtn`。
struct MBtn: View {
    var title: String
    var icon: String? = nil
    var kind: MBtnKind = .primary
    var full: Bool = false
    var height: CGFloat = 50
    var disabled: Bool = false
    /// 覆盖强调色（默认读 `mAccent` = 蓝）。AI 介入命令的 CTA 传 `M.aiAccent` 走紫。
    var tint: Color? = nil
    var action: () -> Void

    @Environment(\.mAccent) private var envAccent
    private var accent: Color { tint ?? envAccent }

    var body: some View {
        Button(action: { if !disabled { action() } }) {
            HStack(spacing: 8) {
                if let icon { MIcon(name: icon, size: 17, color: fg, weight: .semibold) }
                Text(title).font(M.sans(16, weight: .semibold))
            }
            .frame(maxWidth: full ? .infinity : nil)
            .frame(height: height)
            .padding(.horizontal, 18)
            .foregroundStyle(fg)
            .background(bg)
            .overlay(RoundedRectangle(cornerRadius: MRadius.lg).stroke(stroke, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: MRadius.lg))
            .opacity(disabled ? 0.45 : 1)
        }
        .buttonStyle(MPressStyle())
        .disabled(disabled)
    }

    private var fg: Color {
        switch kind {
        case .primary, .danger: return .white
        case .tinted: return accent
        case .dangerTint: return M.danger
        case .secondary: return M.text
        }
    }
    private var bg: Color {
        switch kind {
        case .primary: return accent
        case .danger: return M.danger
        case .tinted: return accent.opacity(0.14)
        case .dangerTint: return .clear
        case .secondary: return M.button
        }
    }
    // v2「填充即边界」：tinted/secondary 靠填充成形，不再描边；dangerTint 属危险态描边，保留。
    private var stroke: Color {
        switch kind {
        case .dangerTint: return M.danger.opacity(0.4)
        default: return .clear
        }
    }
}

/// 圆形头部按钮 `HBtn` / `RoundBtn`。
struct MRoundBtn: View {
    var icon: String
    var filled: Bool = false
    var action: () -> Void
    @Environment(\.mAccent) private var accent

    @Environment(\.mToolbarItem) private var inToolbar

    var body: some View {
        if inToolbar {
            toolbarButton
        } else {
            roundButton
        }
    }

    /// 在系统工具栏里：交给系统画按钮（iOS 26 液态玻璃；iPhone Duo 上随工具栏挪到侧边列）。
    /// 主操作（`filled`）用醒目样式。
    @ViewBuilder private var toolbarButton: some View {
        let button = Button(action: action) {
            Image(systemName: MGlyph.symbol(icon))
        }
        if filled {
            if #available(iOS 26.0, *) {
                button.buttonStyle(.glassProminent).tint(accent)
            } else {
                button.buttonStyle(.borderedProminent).tint(accent)
            }
        } else {
            button
        }
    }

    private var roundButton: some View {
        Button(action: action) {
            MIcon(name: icon, size: filled ? 18 : 16,
                  color: filled ? .white : M.text2,
                  weight: filled ? .semibold : .medium)
                .frame(width: 36, height: 36)
                .background(filled ? accent : M.button)
                .clipShape(Circle())
                // 视觉 36pt，命中区补到 44pt（HIG）。
                .frame(width: M.minTarget, height: M.minTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(MPressStyle())
    }
}

/// 轻按反馈：明显的缩放 + 压暗 + 触感反馈（点按可感知；触感走共用的 `MHaptics`，不和按压动画挤同一拍）。
struct MPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.72 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, pressed in
                if pressed { MHaptics.press(intensity: 0.7) }
            }
    }
}

// MARK: - 输入 MInput

struct MInput: View {
    @Binding var text: String
    var placeholder: String = ""
    var mono: Bool = false
    var secure: Bool = false
    /// 掩码输入框尾部给一个眼睛钮，点一下看原文。只对 `secure` 生效。
    var revealable: Bool = false
    var keyboard: UIKeyboardType = .default
    var autocap: TextInputAutocapitalization = .never
    /// 出现时就拿焦点、弹键盘（点一下才换出来的输入框，别让人再点一次）。
    var autofocus: Bool = false

    @FocusState private var focused: Bool
    @State private var revealed = false
    @Environment(\.mAccent) private var accent

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if secure, !revealed {
                    SecureField(placeholder, text: $text)
                } else {
                    TextField(placeholder, text: $text)
                }
            }
            .focused($focused)
            .font(mono ? M.mono(15) : M.sans(15))
            .foregroundStyle(M.text)
            .textInputAutocapitalization(autocap)
            .autocorrectionDisabled()
            .keyboardType(keyboard)

            if secure, revealable {
                MRevealButton(revealed: revealed, action: toggleReveal)
            }
        }
        .padding(.horizontal, 13).padding(.vertical, 11)
        .background(M.inputBg)
        .overlay(RoundedRectangle(cornerRadius: MRadius.lg).stroke(focused ? accent : .clear, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: MRadius.lg))
        .task {
            guard autofocus else { return }
            // 等这一拍布局落地再给焦点：刚插进视图树的输入框当场要焦点，有时 UIKit 那边还没挂上、要不到。
            await Task.yield()
            focused = true
        }
    }

    /// 掩码 ⇄ 明文。`SecureField` 与 `TextField` 是两个不同的 UIKit 视图，换一个必然丢焦点
    /// —— 原来在编辑就等这拍界面更新落地后把焦点还回去，键盘不收。
    private func toggleReveal() {
        let wasFocused = focused
        revealed.toggle()
        guard wasFocused else { return }
        Task {
            await Task.yield()
            focused = true
        }
    }
}

/// 掩码输入框尾部的眼睛钮：点一下在 •••• 与原文之间切。切换本身由调用方管。
struct MRevealButton: View {
    var revealed: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            MIcon(name: revealed ? "eye" : "eye-off", size: 15, color: M.text3)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(revealed ? "隐藏原文" : "查看原文")
    }
}

struct MTextArea: View {
    @Binding var text: String
    var placeholder: String = ""
    var minHeight: CGFloat = 90
    @FocusState private var focused: Bool
    @Environment(\.mAccent) private var accent

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text(placeholder).font(M.mono(14)).foregroundStyle(M.text4)
                    .padding(.horizontal, 14).padding(.vertical, 12)
            }
            TextEditor(text: $text)
                .focused($focused)
                .font(M.mono(14))
                .foregroundStyle(M.text)
                .scrollContentBackground(.hidden)
                // 弹窗根上的 `mSheetContentMargins` 会一路传进来；文本框内边距自己管，不吃那份
                .contentMargins(.horizontal, 0, for: .scrollContent)
                .padding(.horizontal, 9).padding(.vertical, 5)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
        }
        .frame(minHeight: minHeight, alignment: .topLeading)
        .background(M.inputBg)
        .overlay(RoundedRectangle(cornerRadius: MRadius.lg).stroke(focused ? accent : .clear, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: MRadius.lg))
    }
}

// MARK: - 开关 MSwitch

struct MSwitch: View {
    @Binding var on: Bool
    @Environment(\.mAccent) private var accent
    var body: some View {
        Toggle("", isOn: $on).labelsHidden().tint(accent)
    }
}

// MARK: - 圆形复选框 MCheck（设计稿 m-kit `MCheck`）

/// 圆形多选框：用于多服务器选择 / chmod 权限网格。
struct MCheck: View {
    var checked: Bool
    var partial: Bool = false
    var onChange: (Bool) -> Void
    @Environment(\.mAccent) private var accent
    private var active: Bool { checked || partial }

    var body: some View {
        Button(action: { onChange(!checked) }) {
            ZStack {
                // v2：未选中用中灰填充成形，选中实心 accent + 白勾，不描边
                Circle()
                    .fill(active ? accent : M.fillMed)
                    .frame(width: 22, height: 22)
                if checked {
                    MIcon(name: "check", size: 13, color: .white, weight: .bold)
                } else if partial {
                    RoundedRectangle(cornerRadius: 1).fill(.white).frame(width: 9, height: 2.2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(MPressStyle())
    }
}

// MARK: - 状态点 SDot / Dot

/// 状态点（可选呼吸光晕）。
///
/// 光晕走 CA 驱动的 `PulseDot`（见 `uTerm/Shared/Views/CAMotion.swift`），不再用
/// SwiftUI `.repeatForever` —— 后者会把整屏钉在每帧重绘上，代价跟视图树大小成正比
/// 而不是跟这个 9pt 小圆点成正比（macOS 侧实测同样的写法让 app 空载吃 30%+ CPU）。
///
/// 顺带解决了原实现的一个行为 bug：旧版靠 `@State anim` + `onAppear` / `onChange`
/// 点火，而这个视图**建出来的时候往往还不该呼吸**（并行执行先 `.pending` 后
/// `.running`，终端标签先 `.idle` 后 `.connecting`），点火时机很容易错过。现在
/// `pulse:` 直接透传，状态一到就动、一走就停，没有中间状态。
struct MDot: View {
    var color: Color
    var pulse: Bool = false
    var size: CGFloat = 9

    var body: some View {
        PulseDot(
            color: color,
            coreSize: size,
            haloSize: size,
            // 与原实现逐参数等价：0.9 → 1.9 扩散、0.3 → 0 淡出、2s、单向不往复。
            scale: 0.9...1.9,
            peakOpacity: 0.3,
            duration: 2.0,
            autoreverses: false,
            pulse: pulse
        )
    }
}

// MARK: - Chip

struct MChip: View {
    var text: String
    var icon: String? = nil
    var tone: ChipTone = .neutral
    enum ChipTone { case neutral, accent }
    @Environment(\.mAccent) private var accent

    var body: some View {
        HStack(spacing: 4) {
            if let icon { MIcon(name: icon, size: 10, color: fg) }
            Text(text).font(M.sans(11, weight: .medium)).lineLimit(1)
        }
        // 窄屏（iPhone Duo 分屏 ≈ 330pt）下宁可让同行的次要信息让位，也不把 chip 折成两行。
        .fixedSize()
        .foregroundStyle(fg)
        .padding(.horizontal, 8).padding(.vertical, 2.5)
        // 中性 chip 用 fillSoft：常嵌在 fillFaint 卡片里，深一档才成形
        .background(tone == .accent ? accent.opacity(0.12) : UD.fillSoft)
        .clipShape(RoundedRectangle(cornerRadius: MRadius.xs))
    }
    private var fg: Color { tone == .accent ? accent : M.text3 }
}

// MARK: - 分组内嵌列表 InsetGroup / InsetRow（iOS 设置风格）

struct MInsetGroup<Content: View>: View {
    var header: String? = nil
    /// 区段标题右侧的小操作（例如「扫码配对」）。
    var headerTrailing: AnyView? = nil
    var footer: String? = nil
    /// 行数可能上千（如已知主机指纹）时置 true：行按需构建，而不是一打开就全部建出来。
    var lazy = false
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let header {
                // 区段标题与脚注是信息层（text3），不是装饰层（text4 只给分隔线 / 行号 / 禁用态）。
                HStack(alignment: .firstTextBaseline) {
                    Text(header.uppercased())
                        .font(M.sans(12, weight: .semibold))
                        .tracking(0.4)
                        .foregroundStyle(M.text3)
                    Spacer(minLength: 8)
                    if let headerTrailing { headerTrailing }
                }
                .padding(.horizontal, 20).padding(.bottom, 7)
            }
            Group {
                if lazy { LazyVStack(spacing: 0) { content } } else { VStack(spacing: 0) { content } }
            }
                .background(M.card)
                .clipShape(RoundedRectangle(cornerRadius: MRadius.list))
                .padding(.horizontal, 16)
            if let footer {
                Text(footer)
                    .font(M.sans(12))
                    .foregroundStyle(M.text3)
                    .lineSpacing(3)
                    .padding(.horizontal, 20).padding(.top, 7)
            }
        }
        .padding(.bottom, 22)
    }
}

/// 行分隔线：对齐系统 List 默认样式（hairline 粗细 + 系统 separator 色）。
/// `inset` 为左缩进，按系统惯例与行内标题文本起点对齐（图标行传图标后的文本起点）；0 = 通栏。
struct MRowDivider: View {
    var inset: CGFloat = 14
    var body: some View {
        Divider().padding(.leading, inset)
    }
}

struct MInsetRow: View {
    var icon: String? = nil
    var iconColor: Color? = nil
    var label: String
    var sub: String? = nil
    /// 副标题是地址、路径这类要逐字看的内容时用等宽（默认）；是一句话（「由某某添加」）时关掉。
    var subMono: Bool = true
    /// 标题和副标题是整句话、截断了就看不懂时打开：标题不限行，副标题最多三行。默认各一行。
    var wraps: Bool = false
    var value: String? = nil
    var valueMono: Bool = false
    var chevron: Bool = false
    var danger: Bool = false
    var last: Bool = false
    var trailing: AnyView? = nil
    var onTap: (() -> Void)? = nil

    @Environment(\.mAccent) private var accent

    var body: some View {
        let row = HStack(spacing: 12) {
            if let icon {
                let c = danger ? M.danger : (iconColor ?? accent)
                MIcon(name: icon, size: 16, color: c)
                    .frame(width: 30, height: 30)
                    .background(c.opacity(0.14))
                    // 与 `MInsetGroup` 卡片同心：50pt 行高里 30pt 图标上下各距卡片边 10pt
                    .clipShape(RoundedRectangle(cornerRadius: MRadius.inner(of: MRadius.list, inset: 10)))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(M.sans(15, weight: .medium))
                    .foregroundStyle(danger ? M.danger : M.text)
                    .lineLimit(wraps ? nil : 1)
                    .fixedSize(horizontal: false, vertical: wraps)
                if let sub {
                    Text(sub).font(subMono ? M.mono(12) : M.sans(12)).foregroundStyle(M.text3)
                        .lineLimit(wraps ? 3 : 1)
                        .fixedSize(horizontal: false, vertical: wraps)
                }
            }
            Spacer(minLength: 8)
            if let value {
                Text(value).font(valueMono ? M.mono(13) : M.sans(14))
                    .foregroundStyle(M.text3).lineLimit(1)
            }
            if let trailing { trailing }
            if chevron { MIcon(name: "chev", size: 14, color: M.text4, weight: .semibold) }
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .frame(minHeight: 50)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) {
            if !last { MRowDivider(inset: icon != nil ? 56 : 14) }
        }

        if let onTap {
            Button(action: onTap) { row }.buttonStyle(MRowStyle())
        } else {
            row
        }
    }
}

/// 行按压高亮（设计稿 `.mk-row:active`）+ 触感反馈。
struct MRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            // 按压态中性灰（对齐 macOS panelHover）；强调色淡底只留给「选中」。
            .background(configuration.isPressed ? M.pressed : .clear)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, pressed in
                if pressed { MHaptics.press(intensity: 0.5) }
            }
    }
}

// MARK: - 区段说明 / 表单字段

struct MSectionCap: View {
    var text: String
    var body: some View {
        Text(text.uppercased()).font(M.sans(11, weight: .semibold))
            .tracking(0.5).foregroundStyle(M.text3)
    }
}

struct MField<Content: View>: View {
    var label: String
    var hint: String? = nil
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(label).font(M.sans(13, weight: .semibold)).foregroundStyle(M.text2)
                if let hint { Text(hint).font(M.sans(12)).foregroundStyle(M.text4) }
            }
            content
        }
    }
}

// MARK: - 可复制 mono 值

struct MCopyField: View {
    var value: String
    var mono: Bool = true
    @State private var done = false
    var body: some View {
        HStack(spacing: 10) {
            Text(value).font(mono ? M.mono(12.5) : M.sans(12.5))
                .foregroundStyle(M.text2)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 6)
            Button {
                UIPasteboard.general.string = value
                done = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { done = false }
            } label: {
                Text(done ? "已拷贝" : "拷贝")
                    .font(M.sans(11.5))
                    .foregroundStyle(done ? M.success : M.text3)
                    .padding(.horizontal, 10).frame(height: 26)
                    .background(M.panel)
                    .overlay(RoundedRectangle(cornerRadius: MRadius.xs).stroke(M.border, lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: MRadius.xs))
            }
            .buttonStyle(MPressStyle())
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(M.fillFaint)
        // 与「复制」钮同心（钮距上下边 10pt）
        .clipShape(RoundedRectangle(cornerRadius: MRadius.concentric(MRadius.xs, inset: 10)))
    }
}

// MARK: - 分段控件 Segmented

struct MSegmented<T: Hashable>: View {
    var items: [(value: T, label: String)]
    @Binding var selection: T
    @Environment(\.mAccent) private var accent

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.value) { item in
                let active = item.value == selection
                Text(item.label)
                    .font(M.sans(13, weight: active ? .semibold : .medium))
                    .foregroundStyle(active ? accent : M.text2)
                    .frame(maxWidth: .infinity).frame(height: 30)
                    .background(active ? accent.opacity(0.14) : .clear)
                    .clipShape(RoundedRectangle(cornerRadius: MRadius.sm))
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { selection = item.value } }
                    .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(2)
        .background(M.inputBg)
        .clipShape(RoundedRectangle(cornerRadius: MRadius.concentric(MRadius.sm, inset: 2)))
    }
}

// MARK: - 搜索框

struct MSearchField: View {
    @Binding var text: String
    var placeholder: String = String(localized: "搜索")
    @FocusState private var focused: Bool
    @Environment(\.mAccent) private var accent
    var body: some View {
        HStack(spacing: 8) {
            MIcon(name: "search", size: 14, color: M.text3)
            TextField(placeholder, text: $text)
                .focused($focused)
                .font(M.sans(15)).foregroundStyle(M.text)
                .autocorrectionDisabled().textInputAutocapitalization(.never)
            if !text.isEmpty {
                Button { text = "" } label: { MIcon(name: "x", size: 13, color: M.text3) }
            }
        }
        .padding(.horizontal, 12).frame(height: 38)
        .background(M.inputBg)
        .overlay(RoundedRectangle(cornerRadius: MRadius.md).stroke(focused ? accent : .clear, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: MRadius.md))
    }
}

// MARK: - Accent 环境注入

private struct MAccentKey: EnvironmentKey {
    static let defaultValue: Color = .blue
}
extension EnvironmentValues {
    var mAccent: Color {
        get { self[MAccentKey.self] }
        set { self[MAccentKey.self] = newValue }
    }
}

// MARK: - 卡片列表（弹性间距）

/// 卡片之间的间距：窄屏（< 600pt：iPhone、Duo 折叠）10pt，宽屏（Duo 展开、iPad）12pt。
///
/// 原先按宽度 5% 弹性取 14–24pt，卡片本身已有 14pt 内边距 + 填充底色，再隔 20pt 上下显得松散、
/// 一屏装不下几张（实机反馈「缩窄卡片间距」）。卡片网格的常见做法是 8–12pt 的槽宽：既能
/// 分清卡片，又让同组卡片读成一组；组与组之间靠分组标题上方更大的留白（见各屏 sectionLabel）
/// 区分，而不是加大卡片间距。未量到宽度前按窄屏处理。
nonisolated func mCardSpacing(for width: CGFloat) -> CGFloat {
    width >= 600 ? 12 : 10
}

/// 卡片网格：窄屏一列（与 `MCardList` 一致），宽屏（iPhone Duo 展开、iPad、横屏）按可用宽度
/// 排 2–3 列。每列至少 `minColumnWidth`，最多 `maxColumns` 列；列间距与行间距同 `mCardSpacing`。
nonisolated func mCardColumns(for width: CGFloat, minColumnWidth: CGFloat = M.cardMinColumnWidth,
                              maxColumns: Int = 3) -> Int {
    guard width > 0 else { return 1 }
    let spacing = mCardSpacing(for: width)
    let fit = Int((width + spacing) / (minColumnWidth + spacing))
    return min(max(fit, 1), maxColumns)
}

struct MCardGrid<Content: View>: View {
    var maxColumns: Int = 3
    /// 关掉懒加载：内容高度一开始就是准的，代价是卡片全部常驻。见 `MCardList.lazy`。
    var lazy: Bool = true
    @ViewBuilder var content: Content

    @State private var width: CGFloat = 0

    var body: some View {
        let spacing = mCardSpacing(for: width)
        let count = mCardColumns(for: width, maxColumns: maxColumns)
        let columns = Array(repeating: GridItem(.flexible(), spacing: spacing, alignment: .top),
                            count: count)
        Group {
            if lazy {
                LazyVGrid(columns: columns, alignment: .leading, spacing: spacing) {
                    content
                }
            } else {
                MEagerCardColumns(columns: count, spacing: spacing) {
                    content
                }
            }
        }
        // LazyVGrid 不会把格子拉到整行同高：行数可变的卡片据此在多列时预留满行数。
        .environment(\.mCardGridColumns, count)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}

/// `MCardGrid` 的非懒加载版：等宽多列，每行取最高卡片的高度，格子顶部对齐（与 LazyVGrid 的 `.top` 一致）。
///
/// 量过的行高按格子宽度缓存：一次排版先 `sizeThatFits` 再 `placeSubviews`，两步共用一份，每张卡片只量一遍。
/// SwiftUI 每次重新排版前都会调 `updateCache`（2026-11-16 Duo 实测：每次 `sizeThatFits` 前都调），在那里清掉，
/// 所以跨排版的复用指望不上。
private struct MEagerCardColumns: Layout {
    var columns: Int
    var spacing: CGFloat

    struct Cache {
        var cellWidth: CGFloat?
        var heights: [CGFloat] = []
    }

    func makeCache(subviews: Subviews) -> Cache { Cache() }

    func updateCache(_ cache: inout Cache, subviews: Subviews) { cache = Cache() }

    private func cellWidth(in width: CGFloat) -> CGFloat {
        max(0, (width - spacing * CGFloat(columns - 1)) / CGFloat(columns))
    }

    private func rowHeights(_ subviews: Subviews, cellWidth: CGFloat, cache: inout Cache) -> [CGFloat] {
        if cache.cellWidth == cellWidth { return cache.heights }
        let heights = stride(from: 0, to: subviews.count, by: columns).map { start in
            subviews[start..<min(start + columns, subviews.count)].map {
                $0.sizeThatFits(ProposedViewSize(width: cellWidth, height: nil)).height
            }.max() ?? 0
        }
        cache = Cache(cellWidth: cellWidth, heights: heights)
        return heights
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let width = proposal.width ?? 0
        let heights = rowHeights(subviews, cellWidth: cellWidth(in: width), cache: &cache)
        return CGSize(width: width, height: heights.reduce(0, +) + spacing * CGFloat(max(0, heights.count - 1)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let cell = cellWidth(in: bounds.width)
        var y = bounds.minY
        for (row, height) in rowHeights(subviews, cellWidth: cell, cache: &cache).enumerated() {
            for column in 0..<columns where row * columns + column < subviews.count {
                subviews[row * columns + column].place(
                    at: CGPoint(x: bounds.minX + CGFloat(column) * (cell + spacing), y: y),
                    proposal: ProposedViewSize(width: cell, height: nil))
            }
            y += height + spacing
        }
    }
}

private struct MCardGridColumnsKey: EnvironmentKey {
    static let defaultValue = 1
}

extension EnvironmentValues {
    /// 卡片所在 `MCardGrid` 当前的列数（不在网格里为 1）。
    var mCardGridColumns: Int {
        get { self[MCardGridColumnsKey.self] }
        set { self[MCardGridColumnsKey.self] = newValue }
    }
}

/// 自量宽度、按 `mCardSpacing` 设置间距的竖向卡片列表容器。
/// 主机 / 终端 / 文件 / 命令四个 tab 的卡片列表共用，替代写死的 spacing。
struct MCardList<Content: View>: View {
    var alignment: HorizontalAlignment = .center
    /// 懒加载时，没画出来的卡片只能估高，滚动中总高度不断被修正。主机页（Duo 真机、真实数据）录到修正时
    /// 整块内容被挪位：滑回顶部偏移正常，内容却往下错开 317pt，手指不动就一直空着。关掉就没有估高。
    var lazy: Bool = true
    @ViewBuilder var content: Content

    @State private var width: CGFloat = 0

    var body: some View {
        Group {
            if lazy {
                LazyVStack(alignment: alignment, spacing: mCardSpacing(for: width)) {
                    content
                }
            } else {
                VStack(alignment: alignment, spacing: mCardSpacing(for: width)) {
                    content
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}
