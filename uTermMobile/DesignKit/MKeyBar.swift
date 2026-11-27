import SwiftUI
import UIKit

// MARK: - 键盘条外壳

/// 软键盘上方的快捷键条：一行常驻键 + 按需打开的面板。终端（`TerminalKeyBar`）与远程桌面
///（`RemoteDesktopKeyBar`）共用，两边只是发出去的东西不同（终端转义序列 / Mac 键码）。
///
/// 面板占键盘的位置（聊天软件的「+」面板那样），不和键盘叠着把正文挤没；两者同一时间只出现一个：
/// 打开面板时收起键盘、关面板时还原，键盘回来（点正文、点键盘按钮）面板就让位。外接键盘不占屏幕，
/// 也就不用让位，否则面板开着就打不了字。
struct MKeyBar<Panel: Hashable, Leading: View, Row: View, Trailing: View, PanelContent: View>: View {
    @Binding var panel: Panel?
    /// 系统键盘此刻占着屏幕（外面用它决定开面板时要不要收键盘）。外接键盘时正文也是第一响应者，
    /// 但屏幕上没有键盘，所以不能看响应者。
    @Binding var softKeyboardUp: Bool
    /// 面板顶上的分段切换（按键 / AI）。只有一个面板时传空数组，不显示。
    var tabs: [(value: Panel, label: String)] = []
    /// 固定在最左、不跟着滚的键（面板入口）：键盘条的第一位，拇指最顺手、滚到哪都点得到。
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let row: () -> Row
    /// 固定在最右、不跟着滚的键（收起 / 弹出键盘），否则要先滚过一整排键才够得到。
    @ViewBuilder let trailing: () -> Trailing
    @ViewBuilder let content: (Panel) -> PanelContent
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    /// 键盘条底下的安全区（SwiftUI 的，键盘也算在里面）与窗口根视图的底部安全区（UIKit 的，只有 Home 条那一截）。
    /// 两个相等才说明下面只有 Home 条，见 `MKeyBarBottomInset`。
    @State private var bottomSafeArea: CGFloat = 0
    @State private var windowBottomSafeArea: CGFloat = 0
    /// 常驻那一行在窗口里的位置与窗口的圆角，两端的键按它让开圆角（见 `MKeyBarCornerClearance`）。
    @State private var rowFrame: CGRect = .zero
    @State private var windowCorners = MWindowCorners()
    @Environment(\.layoutDirection) private var layoutDirection

    /// 两端固定键离这一行左右边沿的距离：平时 10pt，贴着屏幕下面两个圆角时再往里让。
    private var rowPadding: (leading: CGFloat, trailing: CGFloat) {
        let base: CGFloat = 10
        let left = MKeyBarCornerClearance.padding(base: base, row: rowFrame, corners: windowCorners, edge: .left)
        let right = MKeyBarCornerClearance.padding(base: base, row: rowFrame, corners: windowCorners, edge: .right)
        return layoutDirection == .leftToRight ? (left, right) : (right, left)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let panel {
                VStack(spacing: 0) {
                    // 分段钉在面板顶上、不跟着内容滚：切到另一个面板不用先滚回顶。
                    if tabs.count > 1 {
                        MSegmented(items: tabs, selection: Binding(get: { panel }, set: { self.panel = $0 }))
                            .padding(.horizontal, 10).padding(.top, 8)
                    }
                    ScrollView(.vertical, showsIndicators: true) {
                        VStack(alignment: .leading, spacing: 12) { content(panel) }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    // 换面板时回到顶上，不沿用上一个面板滚到的位置。
                    .id(panel)
                }
                // 高度固定：两个面板之间切换时正文不跟着改尺寸。横屏矮，留够正文的位置。
                .frame(height: verticalSizeClass == .compact ? 150 : 240)
                Rectangle().fill(M.divider).frame(height: 1)
            }
            HStack(spacing: 6) {
                // 两头各固定一个键，中间整排一起滚。分屏后一格很窄，固定的键不能再多。
                leading().padding(.leading, rowPadding.leading)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) { row() }
                }
                .mKeepsScrollContentInSafeArea()
                trailing().padding(.trailing, rowPadding.trailing)
            }
            // 这一行往下伸进了 Home 条那一截，两端的键正落在屏幕下面两个圆角里（实机：Duo 内外屏、横竖握都有一截
            // 画到圆角外面）。左右让多少按行的位置与窗口圆角算；改的是行内的边距，行自己的位置不变，不会来回牵动。
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { rowFrame = $0 }
            .background { MWindowCornerProbe { windowCorners = $0 } }
        }
        // 与正文同一个工作面，只用顶边 hairline 分区（「线或底色差，二选一」）。
        .background(M.surface, ignoresSafeAreaEdges: .mSessionBody)
        .overlay(alignment: .top) { Rectangle().fill(M.divider).frame(height: 1) }
        // 往下伸进 Home 条那一截：报给外面的高度少这么多，正文就多这么多；键自己画在安全区里。
        .padding(.bottom, softKeyboardUp ? 0 : -MKeyBarBottomInset.reclaimed(safeAreaBottom: bottomSafeArea,
                                                                              containerBottom: windowBottomSafeArea))
        // 量的是收回之后、仍在安全区内的这一块：它的下沿贴着安全区边界，读到的就是整段安全区，不会和上面那行互相牵动。
        .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.bottom } action: { bottomSafeArea = $0 }
        // 不能拿 `.ignoresSafeArea(.keyboard)` 的视图量「不算键盘」的那份：它读到的照样含键盘（实机：键盘条躲到了
        // 键盘后面）。改问 UIKit：根视图的安全区没有键盘。
        .background { MWindowBottomInsetProbe { windowBottomSafeArea = $0 } }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
            guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
                  let screen = note.object as? UIScreen else { return }
            softKeyboardUp = MKeyBarKeyboard.coversScreen(frame: frame, screenHeight: screen.bounds.height)
        }
        .onChange(of: softKeyboardUp) { _, up in
            if up { panel = nil }
        }
    }
}

nonisolated enum MKeyBarKeyboard {
    /// 外接键盘时系统只留一条几十点高的快捷栏（或者什么都没有），不算占屏。
    static func coversScreen(frame: CGRect, screenHeight: CGFloat) -> Bool {
        screenHeight - frame.minY > 120
    }
}

/// 面板开关：开面板前记下键盘是否弹着，关面板时还原。
struct MKeyBarPanelSwitch<Panel: Hashable> {
    private var keyboardBeforePanel = false
    /// 键盘条只有一个面板入口：再打开时回到上次看的那一页。
    private(set) var lastPanel: Panel

    init(initial: Panel) { lastPanel = initial }

    /// 面板入口：开着就关，关着就开上次那一页。
    mutating func toggleAny(panel: inout Panel?, softKeyboardUp: Bool,
                            showKeyboard: () -> Void, collapseKeyboard: () -> Void) {
        toggle(panel ?? lastPanel, panel: &panel, softKeyboardUp: softKeyboardUp,
               showKeyboard: showKeyboard, collapseKeyboard: collapseKeyboard)
    }

    /// 面板里切到了另一页（分段）。
    mutating func remember(_ panel: Panel?) {
        if let panel { lastPanel = panel }
    }

    mutating func toggle(_ target: Panel, panel: inout Panel?, softKeyboardUp: Bool,
                         showKeyboard: () -> Void, collapseKeyboard: () -> Void) {
        if panel == target {
            panel = nil
            if keyboardBeforePanel { showKeyboard() }
            return
        }
        if panel == nil { keyboardBeforePanel = softKeyboardUp }
        panel = target
        lastPanel = target
        if softKeyboardUp { collapseKeyboard() }
    }
}

// MARK: - 常驻行的零件

/// 组与组之间多空一点。
struct MKeyBarGap: View {
    var body: some View { Color.clear.frame(width: 4, height: 1) }
}

/// 打开某个面板的图标键；面板开着时点亮。
struct MKeyBarPanelButton: View {
    let symbol: String
    let label: LocalizedStringKey
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) { MKeyIconCap(symbol: symbol, active: active) }
            .buttonStyle(MPressStyle())
            .accessibilityLabel(label)
            .accessibilityAddTraits(active ? .isSelected : [])
    }
}

/// 收起 / 弹出键盘。
struct MKeyBarKeyboardButton: View {
    let shown: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            MKeyIconCap(symbol: shown ? "keyboard.chevron.compact.down" : "keyboard")
        }
        .buttonStyle(MPressStyle())
        .accessibilityLabel(shown ? "收起键盘" : "弹出键盘")
    }
}

// MARK: - 面板的零件

struct MKeyBarSectionTitle: View {
    let title: LocalizedStringKey

    init(_ title: LocalizedStringKey) { self.title = title }

    var body: some View {
        Text(title).font(M.sans(11, weight: .semibold)).foregroundStyle(M.text3)
    }
}

/// 面板里的一组键：标题 + 撑满列宽的键帽网格。
struct MKeyGridSection<Key: Identifiable>: View {
    let title: LocalizedStringKey
    let keys: [Key]
    let label: (Key) -> String
    let action: (Key) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            MKeyBarSectionTitle(title)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 46), spacing: 6)], spacing: 6) {
                ForEach(keys) { key in
                    Button { action(key) } label: { MKeyCap(text: label(key), fill: true) }
                        .buttonStyle(MPressStyle())
                }
            }
        }
    }
}

/// 面板里的一组提示词：点一下发送并提交，长按菜单里可以只填入。
struct MPromptGridSection: View {
    let title: LocalizedStringKey
    let prompts: [String]
    let minWidth: CGFloat
    let mono: Bool
    let submit: (String) -> Void
    let fill: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            MKeyBarSectionTitle(title)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: minWidth), spacing: 6)], spacing: 6) {
                ForEach(prompts, id: \.self) { prompt in
                    Button { submit(prompt) } label: { cap(prompt) }
                        .buttonStyle(MPressStyle())
                        .mContextMenu(preview: RoundedRectangle(cornerRadius: MRadius.sm)) {
                            Button { fill(prompt) } label: { Label("填入，不发送", systemImage: "text.cursor") }
                        }
                }
            }
        }
    }

    private func cap(_ text: String) -> some View {
        Text(verbatim: text)
            .font(mono ? M.mono(13, weight: .medium) : M.sans(13, weight: .medium))
            .foregroundStyle(M.text)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: MKeyCapMetrics.height, maxHeight: MKeyCapMetrics.height,
                   alignment: .leading)
            .background(M.button)
            .clipShape(RoundedRectangle(cornerRadius: MRadius.sm))
            .contentShape(RoundedRectangle(cornerRadius: MRadius.sm))
    }
}

/// AI 面板（终端与远程桌面共用）：启动命令、选项与模式（各端自己的键）、提示词、斜杠命令，底部「编辑短语…」。
///
/// 前台没在跑 AI 命令行时「启动」排最前（要的是先把它开起来），在跑时排最后。只调先后、不藏：判不准时也都点得到。
struct MKeyBarAIPanel<Options: View>: View {
    let phrases: TerminalPhrases
    let agentInForeground: Bool
    let submit: (String) -> Void
    let fill: (String) -> Void
    let edit: () -> Void
    @ViewBuilder let options: () -> Options

    var body: some View {
        Group {
            if agentInForeground {
                options()
                section(.prompt)
                section(.slash)
                section(.launch)
            } else {
                section(.launch)
                options()
                section(.prompt)
                section(.slash)
            }
            MKeyBarEditPhrasesButton(action: edit)
        }
    }

    @ViewBuilder private func section(_ kind: TerminalPhraseKind) -> some View {
        let list = phrases[kind]
        if !list.isEmpty {
            switch kind {
            case .launch:
                MPromptGridSection(title: "启动", prompts: list, minWidth: 150, mono: true, submit: submit, fill: fill)
            case .prompt:
                MPromptGridSection(title: "提示词", prompts: list, minWidth: 150, mono: false, submit: submit, fill: fill)
            case .slash:
                MPromptGridSection(title: "斜杠命令", prompts: list, minWidth: 92, mono: true, submit: submit, fill: fill)
            }
        }
    }
}

/// 面板底部「编辑短语…」：打开短语编辑页（设置 › 终端 › 键盘条短语 的同一页）。
struct MKeyBarEditPhrasesButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("编辑短语…", systemImage: "square.and.pencil")
                .font(M.sans(13, weight: .medium))
                .foregroundStyle(M.text2)
                .frame(maxWidth: .infinity, minHeight: MKeyCapMetrics.height)
                .contentShape(Rectangle())
        }
        .buttonStyle(MPressStyle())
    }
}

// MARK: - 键帽

enum MKeyCapMetrics {
    static let height: CGFloat = 38
    /// 键帽上下各多算这么多点按区域，加上键帽高度正好是整行 48pt，手指不必瞄准键帽。
    static let verticalHitInset: CGFloat = 5
    static let minWidth: CGFloat = 40
    /// 键帽看得见的那块（在撑高的命中区里竖直居中），与键帽底板同款圆角。
    static var capShape: MCenteredRoundedRect {
        MCenteredRoundedRect(cornerRadius: MRadius.sm, height: height, style: .circular)
    }
}

/// 文字键帽；`active` 时用强调色淡底 + 强调色字（修饰上膛态）。`fill` 时撑满网格列宽。
struct MKeyCap: View {
    let text: String
    var active = false
    var fill = false
    @Environment(\.mAccent) private var accent

    var body: some View {
        Text(verbatim: text)
            .font(M.mono(13, weight: .medium))
            .foregroundStyle(active ? accent : M.text)
            .lineLimit(1)
            .padding(.horizontal, fill ? 4 : 10)
            .frame(minWidth: MKeyCapMetrics.minWidth, maxWidth: fill ? .infinity : nil,
                   minHeight: MKeyCapMetrics.height, maxHeight: MKeyCapMetrics.height)
            .background(active ? accent.opacity(0.14) : M.button)
            .clipShape(RoundedRectangle(cornerRadius: MRadius.sm))
            .padding(.vertical, fill ? 0 : MKeyCapMetrics.verticalHitInset)
            .contentShape(Rectangle())
            // 命中区上下撑开了；悬停 / 菜单浮起贴着键帽本身。
            .contentShape([.hoverEffect, .contextMenuPreview], MKeyCapMetrics.capShape)
    }
}

struct MKeyIconCap: View {
    let symbol: String
    var active = false
    @Environment(\.mAccent) private var accent

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(active ? accent : M.text)
            .frame(width: MKeyCapMetrics.minWidth, height: MKeyCapMetrics.height)
            .background(active ? accent.opacity(0.14) : M.button)
            .clipShape(RoundedRectangle(cornerRadius: MRadius.sm))
            .padding(.vertical, MKeyCapMetrics.verticalHitInset)
            .contentShape(Rectangle())
            // 命中区上下撑开了；悬停 / 菜单浮起贴着键帽本身。
            .contentShape([.hoverEffect, .contextMenuPreview], MKeyCapMetrics.capShape)
    }
}

/// 一下一下点的文字键。
struct MKeyButton: View {
    let label: String
    var active = false
    let action: () -> Void

    var body: some View {
        Button(action: action) { MKeyCap(text: label, active: active) }
            .buttonStyle(MPressStyle())
    }
}

// MARK: - 长按连发

/// 按住连发的键帽（方向键）。按压状态只取自 Button 本身，不另挂手势：另挂的手势会抢走滚动，
/// 从方向键起手就拖不动快捷条。滚动接管时 `isPressed` 变回 false，连发随之取消。
struct MRepeatingKeyButton: View {
    let label: String
    let action: () -> Void
    @State private var repeater = KeyRepeater()

    var body: some View {
        Button {
            if !repeater.didRepeat { action() }
        } label: {
            MKeyCap(text: label)
        }
        .buttonStyle(RepeatingPressStyle { pressed in
            if pressed { repeater.press(action) } else { repeater.release() }
        })
        .onDisappear { repeater.release() }
    }
}

private struct RepeatingPressStyle: ButtonStyle {
    let onPressChange: (Bool) -> Void

    func makeBody(configuration: Configuration) -> some View {
        MPressStyle().makeBody(configuration: configuration)
            .onChange(of: configuration.isPressed) { _, pressed in onPressChange(pressed) }
    }
}

@MainActor
final class KeyRepeater {
    /// 这次按压已经连发过：松手时 Button 还会触发一次，不能多发。下一次按下时复位。
    private(set) var didRepeat = false
    private var task: Task<Void, Never>?

    func press(_ action: @escaping () -> Void) {
        task?.cancel()
        didRepeat = false
        task = Task {
            guard (try? await Task.sleep(for: .milliseconds(400))) != nil else { return }
            didRepeat = true
            while !Task.isCancelled {
                action()
                try? await Task.sleep(for: .milliseconds(70))
            }
        }
    }

    func release() {
        task?.cancel()
        task = nil
    }
}

/// 报窗口根视图的底部安全区（UIKit 的安全区不含键盘，只有 Home 条那一截）。
private struct MWindowBottomInsetProbe: UIViewRepresentable {
    let onChange: (CGFloat) -> Void

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.isUserInteractionEnabled = false
        view.onChange = onChange
        return view
    }

    func updateUIView(_ view: ProbeView, context: Context) {
        view.onChange = onChange
        view.report()
    }

    final class ProbeView: UIView {
        var onChange: ((CGFloat) -> Void)?
        private var reported: CGFloat?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            report()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            report()
        }

        override func safeAreaInsetsDidChange() {
            super.safeAreaInsetsDidChange()
            report()
        }

        func report() {
            guard let root = window?.rootViewController?.view else { return }
            let bottom = root.safeAreaInsets.bottom
            guard bottom != reported else { return }
            reported = bottom
            // 布局途中不改 SwiftUI 的状态，下一轮再交出去。
            DispatchQueue.main.async { [weak self] in self?.onChange?(bottom) }
        }
    }
}

/// 键盘条贴着屏幕底边时，Home 条那一截安全区只留一点，其余还给正文。
///
/// 全面屏的底部安全区是 34pt（横握 21pt），整段空着太浪费（实机反馈：Duo 上键盘条下面空出一大条）。
/// Home 条本身只占最下面约 13pt；最后一行的命中区（键帽上下各多 5pt）下面再留 10pt，
/// 看得见的键帽就停在 15pt 处，不压 Home 条。安全区本来就比这小（或者键盘弹着、不贴底边）时照原样。
/// 窗口的大小与下面两个角的圆角半径（iPhone 上就是屏幕的圆角）。读不到（iOS 26 以下）时半径为 0，不让。
nonisolated struct MWindowCorners: Equatable, Sendable {
    var size: CGSize = .zero
    var bottomLeft: CGFloat = 0
    var bottomRight: CGFloat = 0
}

/// 键盘条两端的键让开窗口下面的圆角。
///
/// 键帽是圆角矩形（半径 `MRadius.sm`），屏幕角是半径 R 的圆弧。要求键帽的那个角离圆弧至少 `base`——
/// 和它离屏幕底边、离直边留的一样多。键帽离底边 g：外角那段圆的圆心在 (s + r, H − g − r)，屏幕圆弧的圆心在
/// (R, H − R)，两圆心距离不超过 R − r − base 即可，由此解出离侧边至少 s。键帽高过圆弧（g + r ≥ R）时不用让。
enum MKeyBarCornerClearance {
    /// 键帽可见那块的高度与圆角：行里的键在行高中竖直居中。
    static let capHeight = MKeyCapMetrics.height
    static let capRadius = MRadius.sm

    /// 一端的键离行边沿要多远。`row` 与 `corners.size` 在同一个坐标系（窗口）。
    static func padding(base: CGFloat, row: CGRect, corners: MWindowCorners, edge: HorizontalEdgeSide) -> CGFloat {
        guard row.width > 0, corners.size.width > 0 else { return base }
        let radius = edge == .left ? corners.bottomLeft : corners.bottomRight
        let capBottom = row.midY + capHeight / 2
        let gap = corners.size.height - capBottom
        let fromSide = sideInset(cornerRadius: radius, capBottomGap: gap, capRadius: capRadius, margin: base)
        let rowEdge = edge == .left ? row.minX : corners.size.width - row.maxX
        return max(base, (fromSide - rowEdge).rounded(.up))
    }

    /// 键帽离侧边至少多远（只算圆角，不含平时的边距）。
    static func sideInset(cornerRadius R: CGFloat, capBottomGap g: CGFloat, capRadius r: CGFloat,
                          margin m: CGFloat) -> CGFloat {
        let dy = R - g - r
        guard R > 0, dy > 0 else { return 0 }
        let allowed = R - r - m
        // 底边留得比 margin 还少：整个键挪出圆角那一段。
        guard allowed > dy else { return R - r }
        return R - r - (allowed * allowed - dy * dy).squareRoot()
    }

    enum HorizontalEdgeSide { case left, right }
}

/// 读窗口大小和下面两个角的圆角半径。iOS 26 起用 `containerConcentric`：一个铺满窗口的视图与容器同心，
/// 它的圆角就是窗口（iPhone 上即屏幕）的圆角。
private struct MWindowCornerProbe: UIViewRepresentable {
    let onChange: (MWindowCorners) -> Void

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.isUserInteractionEnabled = false
        view.onChange = onChange
        return view
    }

    func updateUIView(_ view: ProbeView, context: Context) {
        view.onChange = onChange
    }

    final class ProbeView: UIView {
        var onChange: ((MWindowCorners) -> Void)?
        private var reported: MWindowCorners?
        /// 铺满窗口、与容器同心的那个视图（看不见，只用来读圆角）。
        private let concentric = UIView()

        override func didMoveToWindow() {
            super.didMoveToWindow()
            report()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            report()
        }

        override func traitCollectionDidChange(_ previous: UITraitCollection?) {
            super.traitCollectionDidChange(previous)
            report()
        }

        private func report() {
            guard let window else { return }
            var corners = MWindowCorners(size: window.bounds.size)
            if #available(iOS 26.0, *) {
                if concentric.superview !== self {
                    concentric.isUserInteractionEnabled = false
                    concentric.cornerConfiguration = .corners(radius: .containerConcentric())
                    addSubview(concentric)
                }
                concentric.frame = convert(window.bounds, from: window)
                corners.bottomLeft = concentric.effectiveRadius(corner: .bottomLeft)
                corners.bottomRight = concentric.effectiveRadius(corner: .bottomRight)
            }
            guard corners != reported else { return }
            reported = corners
            // 布局途中不改 SwiftUI 的状态，下一轮再交出去。
            DispatchQueue.main.async { [weak self] in self?.onChange?(corners) }
        }
    }
}

nonisolated enum MKeyBarBottomInset {
    static let kept: CGFloat = 10

    /// 从底部安全区里收回多少点。`containerBottom` 是窗口的（不算键盘）：比键盘条读到的小，说明下面是键盘，一点都不收。
    static func reclaimed(safeAreaBottom: CGFloat, containerBottom: CGFloat) -> CGFloat {
        guard safeAreaBottom <= containerBottom + 0.5 else { return 0 }
        return max(safeAreaBottom - kept, 0)
    }
}
