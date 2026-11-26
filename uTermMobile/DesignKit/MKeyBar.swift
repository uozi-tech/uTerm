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
                leading().padding(.leading, 10)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) { row() }
                }
                .mKeepsScrollContentInSafeArea()
                trailing().padding(.trailing, 10)
            }
        }
        // 与正文同一个工作面，只用顶边 hairline 分区（「线或底色差，二选一」）。
        .background(M.surface, ignoresSafeAreaEdges: .mSessionBody)
        .overlay(alignment: .top) { Rectangle().fill(M.divider).frame(height: 1) }
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
