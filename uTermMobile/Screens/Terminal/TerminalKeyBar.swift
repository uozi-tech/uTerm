import PhotosUI
import SwiftUI
import UIKit

/// 键盘条上的一个键：`label` 显示文本、`send` 发给终端的字节序列。
struct TerminalKey: Identifiable, Hashable {
    let label: String
    let send: String
    var id: String { label }

    init(_ label: String, _ send: String) {
        self.label = label
        self.send = send
    }

    /// 符号键：显示什么就发什么。
    init(symbol: String) {
        self.init(symbol, symbol)
    }
}

enum TerminalKeyCatalog {
    static let enter = TerminalKey("↵", "\r")
    static let escape = TerminalKey("esc", "\u{1b}")
    static let shiftTab = TerminalKey("⇧Tab", "\u{1b}[Z")

    /// 常驻行：高频键 → 方向键 → 命令行符号，方向键单独一组（长按连发）。
    static let primary = [escape, TerminalKey("tab", "\t"), enter, TerminalKey("^C", "\u{03}")]
    static let arrows = [
        TerminalKey("←", "\u{1b}[D"), TerminalKey("↑", "\u{1b}[A"),
        TerminalKey("↓", "\u{1b}[B"), TerminalKey("→", "\u{1b}[C"),
    ]
    static let shellSymbols = ["/", "|", "~", "-"].map { TerminalKey(symbol: $0) }

    /// home/end 用 xterm 普通光标态序列。
    static let navigation = [
        TerminalKey("home", "\u{1b}[H"), TerminalKey("end", "\u{1b}[F"),
        TerminalKey("pgUp", "\u{1b}[5~"), TerminalKey("pgDn", "\u{1b}[6~"),
        TerminalKey("del", "\u{1b}[3~"), TerminalKey("ins", "\u{1b}[2~"),
        TerminalKey("⌫", "\u{7f}"), shiftTab,
    ]
    static let control = [
        TerminalKey("^A", "\u{01}"), TerminalKey("^C", "\u{03}"),
        TerminalKey("^D", "\u{04}"), TerminalKey("^E", "\u{05}"),
        TerminalKey("^K", "\u{0b}"), TerminalKey("^L", "\u{0c}"),
        TerminalKey("^R", "\u{12}"), TerminalKey("^U", "\u{15}"),
        TerminalKey("^W", "\u{17}"), TerminalKey("^Z", "\u{1a}"),
    ]
    /// F1–F4 用 SS3，F5–F12 用 CSI ~ 序列，对齐 xterm。
    static let function = [
        TerminalKey("F1", "\u{1b}OP"), TerminalKey("F2", "\u{1b}OQ"),
        TerminalKey("F3", "\u{1b}OR"), TerminalKey("F4", "\u{1b}OS"),
        TerminalKey("F5", "\u{1b}[15~"), TerminalKey("F6", "\u{1b}[17~"),
        TerminalKey("F7", "\u{1b}[18~"), TerminalKey("F8", "\u{1b}[19~"),
        TerminalKey("F9", "\u{1b}[20~"), TerminalKey("F10", "\u{1b}[21~"),
        TerminalKey("F11", "\u{1b}[23~"), TerminalKey("F12", "\u{1b}[24~"),
    ]
    static let symbols = [
        "/", "\\", "|", "~", "-", "_", "=", "+", ":", ";", ",", ".", "?", "!",
        "@", "#", "$", "%", "^", "&", "*", "(", ")", "[", "]", "{", "}", "<", ">",
    ].map { TerminalKey(symbol: $0) }

    /// AI 命令行里的选择题和模式切换：手机键盘打不出 ⇧Tab，确认项也不用先弹键盘。只发按键，不带回车。
    static let agentKeys = [
        TerminalKey(symbol: "1"), TerminalKey(symbol: "2"), TerminalKey(symbol: "3"),
        enter, escape, shiftTab,
    ]
    /// 常用提示词。显示什么就发什么，不放一点就有破坏性的（回退、推送）。
    static let prompts = [
        "继续",
        "按你的方案做",
        "先说方案，别改代码",
        "这个方向不对，换个思路",
        "修复这个错误",
        "跑测试并修复失败项",
        "解释一下刚才的改动",
        "检查刚才的改动有没有问题",
        "总结当前进度和下一步",
        "提交当前改动",
    ]
    /// Claude Code 与 Codex 都支持的斜杠命令。
    static let slashCommands = ["/clear", "/compact", "/resume", "/model", "/status", "/init"]
}

// MARK: - 终端快捷键条

/// 一行常驻键 + 按需打开的面板。面板占键盘的位置（聊天软件的「+」面板那样），不和键盘叠着把终端
/// 挤没；两者同一时间只出现一个。外接键盘不占屏幕，也就不用让位，否则面板开着就打不了字。
struct TerminalKeyBar: View {
    enum Panel: Hashable { case prompts, keys }

    let controller: MobileTerminalController
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var panel: Panel?
    /// 系统键盘此刻占着屏幕。外接键盘时终端也是第一响应者，但屏幕上没有键盘，所以不能看响应者。
    @State private var softKeyboardUp = false
    /// 打开面板前键盘是否弹着：关面板时还原。
    @State private var keyboardBeforePanel = false
    @State private var pickingPhoto = false
    @State private var pickedPhoto: PhotosPickerItem?

    /// `panel` 的初值。生产侧一律省略（收起），探针和样式画廊用它把面板也挂起来。
    init(controller: MobileTerminalController, panel: Panel? = nil) {
        self.controller = controller
        _panel = State(initialValue: panel)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let panel {
                panelContent(panel)
                Rectangle().fill(M.divider).frame(height: 1)
            }
            keyRow
        }
        // 与终端同一个工作面，只用顶边 hairline 分区（「线或底色差，二选一」）。
        .background(M.surface, ignoresSafeAreaEdges: .mSessionBody)
        .overlay(alignment: .top) { Rectangle().fill(M.divider).frame(height: 1) }
        // 贴图的进度 / 结果浮在键盘条上方，不挤终端的行数。
        .overlay(alignment: .top) { imageNote.alignmentGuide(.top) { $0[.bottom] + 8 } }
        .animation(.easeOut(duration: 0.15), value: controller.imageNote)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
            guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
                  let screen = note.object as? UIScreen else { return }
            softKeyboardUp = Self.keyboardCoversScreen(frame: frame, screenHeight: screen.bounds.height)
        }
        // 键盘回来了（点终端、点键盘按钮）就让出位置。
        .onChange(of: softKeyboardUp) { _, up in
            if up { panel = nil }
        }
        .photosPicker(isPresented: $pickingPhoto, selection: $pickedPhoto, matching: .images)
        .onChange(of: pickedPhoto) { _, item in
            guard let item else { return }
            pickedPhoto = nil
            controller.sendImage {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    throw RemoteDesktopPasteSource.Failure.unreadableImage
                }
                return try await RemoteDesktopPasteSource.terminalImage(data: data)
            }
        }
    }

    /// 外接键盘时系统只留一条几十点高的快捷栏（或者什么都没有），不算占屏。
    nonisolated static func keyboardCoversScreen(frame: CGRect, screenHeight: CGFloat) -> Bool {
        screenHeight - frame.minY > 120
    }

    private func toggle(_ target: Panel) {
        if panel == target {
            panel = nil
            if keyboardBeforePanel { controller.showKeyboard() }
            return
        }
        if panel == nil { keyboardBeforePanel = softKeyboardUp }
        panel = target
        if softKeyboardUp { controller.collapseKeyboard() }
    }

    @ViewBuilder private var imageNote: some View {
        if let note = controller.imageNote {
            Text(note)
                .font(M.sans(12, weight: .medium))
                .foregroundStyle(M.text)
                .lineLimit(2)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(M.button)
                .clipShape(RoundedRectangle(cornerRadius: MRadius.sm))
                .padding(.horizontal, 10)
                .transition(.opacity)
        }
    }

    // MARK: 常驻行

    private var keyRow: some View {
        HStack(spacing: 6) {
            // 整排一起滚：分屏后一格很窄，固定在左边的键会占掉大半宽度。
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    panelButton(.keys, symbol: "square.grid.2x2", label: "更多按键")
                    panelButton(.prompts, symbol: "text.bubble", label: "AI 提示词")
                    groupGap
                    modifierKey("ctrl", armed: controller.controlArmed) { controller.toggleControl() }
                    modifierKey("alt", armed: controller.altArmed) { controller.toggleAlt() }
                    if controller.acceptsImages { imageMenu }
                    groupGap
                    keyButtons(TerminalKeyCatalog.primary)
                    groupGap
                    ForEach(TerminalKeyCatalog.arrows) { key in
                        RepeatingKeyCap(key: key) { send(key) }
                    }
                    groupGap
                    keyButtons(TerminalKeyCatalog.shellSymbols)
                }
                .padding(.leading, 10)
            }
            .mKeepsScrollContentInSafeArea()
            keyboardButton.padding(.trailing, 10)
        }
    }

    private var groupGap: some View { Color.clear.frame(width: 4, height: 1) }

    private func panelButton(_ target: Panel, symbol: String, label: LocalizedStringKey) -> some View {
        Button { toggle(target) } label: {
            TerminalIconCap(symbol: symbol, active: panel == target)
        }
        .buttonStyle(MPressStyle())
        .accessibilityLabel(label)
        .accessibilityAddTraits(panel == target ? .isSelected : [])
    }

    /// 粘滞修饰只作用于系统键盘的下一个字符，所以上膛时键盘必须在。
    private func modifierKey(_ label: String, armed: Bool, toggle: @escaping () -> Void) -> some View {
        Button {
            toggle()
            if !armed { controller.showKeyboard() }
        } label: {
            TerminalKeyCap(text: label, active: armed)
        }
        .buttonStyle(MPressStyle())
    }

    private func keyButtons(_ keys: [TerminalKey], fill: Bool = false) -> some View {
        ForEach(keys) { key in
            Button { send(key) } label: { TerminalKeyCap(text: key.label, fill: fill) }
                .buttonStyle(MPressStyle())
        }
    }

    /// 贴图片：剪贴板里的图，或相册里选一张。直连服务器传成 `/tmp` 下的文件并粘上路径；
    /// Mac 本机终端放进 Mac 剪贴板再按 Ctrl+V（Claude Code 等从剪贴板读图）。
    private var imageMenu: some View {
        Menu {
            Button {
                controller.sendImage { try await RemoteDesktopPasteSource.clipboardImage() }
            } label: { Label("粘贴剪贴板里的图片", systemImage: "doc.on.clipboard") }
            Button { pickingPhoto = true } label: { Label("从相册选择…", systemImage: "photo.on.rectangle") }
        } label: {
            TerminalIconCap(symbol: "photo")
        }
        .accessibilityLabel("贴图片")
    }

    /// 收起 / 弹出键盘。固定在最右、不跟着滚，否则要先滚过一整排键才够得到。
    private var keyboardButton: some View {
        Button {
            if controller.keyboardShown { controller.collapseKeyboard() } else { controller.showKeyboard() }
        } label: {
            TerminalIconCap(symbol: controller.keyboardShown ? "keyboard.chevron.compact.down" : "keyboard")
        }
        .buttonStyle(MPressStyle())
        .accessibilityLabel(controller.keyboardShown ? "收起键盘" : "弹出键盘")
    }

    /// 发送一个键：先清掉粘滞修饰（修饰只作用于系统软键盘字符），再发字节序列。
    private func send(_ key: TerminalKey) {
        controller.clearStickyModifiers()
        controller.sendText(key.send)
    }

    // MARK: 面板

    private func panelContent(_ panel: Panel) -> some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 12) {
                switch panel {
                case .prompts:
                    keySection("选项与模式", TerminalKeyCatalog.agentKeys)
                    promptSection("提示词", TerminalKeyCatalog.prompts, minWidth: 150, mono: false)
                    promptSection("斜杠命令", TerminalKeyCatalog.slashCommands, minWidth: 92, mono: true)
                case .keys:
                    keySection("导航", TerminalKeyCatalog.navigation)
                    keySection("Ctrl", TerminalKeyCatalog.control)
                    keySection("功能键", TerminalKeyCatalog.function)
                    keySection("符号", TerminalKeyCatalog.symbols)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // 高度固定：两个面板之间切换时终端不跟着改行数。横屏矮，留够终端的位置。
        .frame(height: verticalSizeClass == .compact ? 150 : 240)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(M.sans(11, weight: .semibold)).foregroundStyle(M.text3)
    }

    private func keySection(_ title: String, _ keys: [TerminalKey]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle(title)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 46), spacing: 6)], spacing: 6) {
                keyButtons(keys, fill: true)
            }
        }
    }

    private func promptSection(_ title: String, _ prompts: [String], minWidth: CGFloat, mono: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle(title)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: minWidth), spacing: 6)], spacing: 6) {
                ForEach(prompts, id: \.self) { prompt in
                    Button { submit(prompt) } label: { promptCap(prompt, mono: mono) }
                        .buttonStyle(MPressStyle())
                        .contextMenu {
                            Button { fill(prompt) } label: { Label("填入，不发送", systemImage: "text.cursor") }
                        }
                }
            }
        }
    }

    private func promptCap(_ text: String, mono: Bool) -> some View {
        Text(verbatim: text)
            .font(mono ? M.mono(13, weight: .medium) : M.sans(13, weight: .medium))
            .foregroundStyle(M.text)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: TerminalKeyCapMetrics.height,
                   maxHeight: TerminalKeyCapMetrics.height, alignment: .leading)
            .background(M.button)
            .clipShape(RoundedRectangle(cornerRadius: MRadius.sm))
            .contentShape(RoundedRectangle(cornerRadius: MRadius.sm))
    }

    /// 发完收起面板、不弹键盘：接下来是看 AI 输出。
    private func submit(_ prompt: String) {
        panel = nil
        controller.clearStickyModifiers()
        controller.submitPrompt(prompt)
    }

    /// 只填入：接下来要接着打字，键盘弹出来（键盘回来时面板会自己让位）。
    private func fill(_ prompt: String) {
        panel = nil
        controller.clearStickyModifiers()
        controller.insertPrompt(prompt)
        controller.showKeyboard()
    }
}

// MARK: - 键帽

private enum TerminalKeyCapMetrics {
    static let height: CGFloat = 38
    /// 键帽上下各多算这么多点按区域，加上键帽高度正好是整行 48pt，手指不必瞄准键帽。
    static let verticalHitInset: CGFloat = 5
    static let minWidth: CGFloat = 40
}

/// 文字键帽；`active` 时用强调色淡底 + 强调色字（修饰上膛态）。`fill` 时撑满网格列宽。
private struct TerminalKeyCap: View {
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
            .frame(minWidth: TerminalKeyCapMetrics.minWidth, maxWidth: fill ? .infinity : nil,
                   minHeight: TerminalKeyCapMetrics.height, maxHeight: TerminalKeyCapMetrics.height)
            .background(active ? accent.opacity(0.14) : M.button)
            .clipShape(RoundedRectangle(cornerRadius: MRadius.sm))
            .padding(.vertical, fill ? 0 : TerminalKeyCapMetrics.verticalHitInset)
            .contentShape(Rectangle())
    }
}

private struct TerminalIconCap: View {
    let symbol: String
    var active = false
    @Environment(\.mAccent) private var accent

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(active ? accent : M.text)
            .frame(width: TerminalKeyCapMetrics.minWidth, height: TerminalKeyCapMetrics.height)
            .background(active ? accent.opacity(0.14) : M.button)
            .clipShape(RoundedRectangle(cornerRadius: MRadius.sm))
            .padding(.vertical, TerminalKeyCapMetrics.verticalHitInset)
            .contentShape(Rectangle())
    }
}

// MARK: - 长按连发

/// 按住连发的键帽（方向键）。按压状态只取自 Button 本身，不另挂手势：另挂的手势会抢走滚动，
/// 从方向键起手就拖不动快捷条。滚动接管时 `isPressed` 变回 false，连发随之取消。
private struct RepeatingKeyCap: View {
    let key: TerminalKey
    let action: () -> Void
    @State private var repeater = KeyRepeater()

    var body: some View {
        Button {
            if !repeater.didRepeat { action() }
        } label: {
            TerminalKeyCap(text: key.label)
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
