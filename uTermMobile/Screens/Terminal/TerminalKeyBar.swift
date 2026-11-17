import PhotosUI
import SwiftUI
import UIKit

/// 键盘条上的一个键：`label` 显示文本、`send` 是它在普通模式下的字节序列——既是这个键的身份（`GhosttyKeyBarMapping`
/// 按它对到终端按键，由终端按当前模式编码），也是没有 surface 可编码时的退路。
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

    static let tab = TerminalKey("tab", "\t")
    static let interrupt = TerminalKey("^C", "\u{03}")

    /// 常驻行的顺序按「手机竖屏第一屏放得下什么」排：esc / tab 和方向键在最前（shell 补全、翻历史、
    /// AI 命令行里选选项都靠它们），修饰键其次，再往后是 ^C / ↵ / ⇧Tab 和命令行符号。方向键长按连发。
    static let leading = [escape, tab]
    static let arrows = [
        TerminalKey("←", "\u{1b}[D"), TerminalKey("↑", "\u{1b}[A"),
        TerminalKey("↓", "\u{1b}[B"), TerminalKey("→", "\u{1b}[C"),
    ]
    /// 修饰键之后的一组：中断、回车（键盘收着、看 AI 输出时要用），⇧Tab（Claude Code / Codex 切模式，手机键盘打不出）。
    static let trailing = [interrupt, enter, shiftTab]
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
}

// MARK: - 终端快捷键条

/// 终端的快捷键条：外壳与键帽见 `MKeyBar`（远程桌面共用），这里只管发什么给终端。
///
/// 常驻行：最左固定一个面板入口（按键 / AI 两个面板共用，面板顶上分段切换），中间滚动的是直接发的键
///（顺序见 `TerminalKeyCatalog.leading`），最右固定键盘钮。
struct TerminalKeyBar: View {
    enum Panel: Hashable { case prompts, keys }

    let controller: MobileTerminalController
    /// 前台在跑 AI 命令行（见 `TermTab.agentInForeground`）。只决定 AI 面板里各组的先后，不藏任何一组：
    /// 没装 shell 集成、不报状态的主机上它判不准。
    let agentInForeground: Bool
    @State private var panel: Panel?
    @State private var panels = MKeyBarPanelSwitch<Panel>(initial: .prompts)
    @State private var softKeyboardUp = false
    @State private var pickingPhoto = false
    @State private var pickedPhoto: PhotosPickerItem?
    @State private var editingPhrases = false
    @AppStorage(DefaultsKey.terminalKeyBarPhrases) private var phrasesRaw = ""

    /// `panel` 的初值。生产侧一律省略（收起），探针和样式画廊用它把面板也挂起来。
    init(controller: MobileTerminalController, agentInForeground: Bool = false, panel: Panel? = nil) {
        self.controller = controller
        self.agentInForeground = agentInForeground
        _panel = State(initialValue: panel)
    }

    static let tabs: [(value: Panel, label: String)] = [
        (.prompts, String(localized: "AI")), (.keys, String(localized: "按键")),
    ]

    var body: some View {
        MKeyBar(panel: $panel, softKeyboardUp: $softKeyboardUp, tabs: Self.tabs) {
            MKeyBarPanelButton(symbol: "square.grid.2x2", label: "按键与 AI 短语", active: panel != nil) {
                panels.toggleAny(panel: &panel, softKeyboardUp: softKeyboardUp,
                                 showKeyboard: controller.showKeyboard, collapseKeyboard: controller.collapseKeyboard)
            }
        } row: {
            keyRow
        } trailing: {
            MKeyBarKeyboardButton(shown: controller.keyboardShown) {
                if controller.keyboardShown { controller.collapseKeyboard() } else { controller.showKeyboard() }
            }
        } content: { panel in
            panelContent(panel)
        }
        // 贴图的进度 / 结果浮在键盘条上方，不挤终端的行数。
        .overlay(alignment: .top) { imageNote.alignmentGuide(.top) { $0[.bottom] + 8 } }
        .animation(.easeOut(duration: 0.15), value: controller.imageNote)
        .photosPicker(isPresented: $pickingPhoto, selection: $pickedPhoto, matching: .images)
        .onChange(of: pickedPhoto) { _, item in
            guard let item else { return }
            pickedPhoto = nil
            controller.sendImage { try await RemoteDesktopPasteSource.terminalImage(photo: item) }
        }
        .onChange(of: panel) { _, panel in panels.remember(panel) }
        .sheet(isPresented: $editingPhrases) {
            TerminalPhrasesScreen(showsDone: true)
        }
    }

    @ViewBuilder private var imageNote: some View {
        if let note = controller.imageNote {
            MKeyBarNote(text: note.text, progress: note.progress)
                .padding(.horizontal, 10)
                .transition(.opacity)
        }
    }

    // MARK: 常驻行

    @ViewBuilder private var keyRow: some View {
        keyButtons(TerminalKeyCatalog.leading)
        // 贴图常用（给 AI 命令行看截图）、查找也是，都紧跟 esc / tab，不用滚就点得到；固定键不再加（分屏后一格太窄）。
        if controller.acceptsImages {
            imageMenu
        }
        searchKey
        MKeyBarGap()
        ForEach(TerminalKeyCatalog.arrows) { key in
            MRepeatingKeyButton(label: key.label) { send(key) }
        }
        MKeyBarGap()
        modifierKey("ctrl", armed: controller.controlArmed) { controller.toggleControl() }
        modifierKey("alt", armed: controller.altArmed) { controller.toggleAlt() }
        MKeyBarGap()
        keyButtons(TerminalKeyCatalog.trailing)
        MKeyBarGap()
        keyButtons(TerminalKeyCatalog.shellSymbols)
    }

    /// 回滚区查找：开着时再点一下关掉。
    private var searchKey: some View {
        Button {
            if controller.search.isPresented { controller.search.dismiss() } else { controller.search.present() }
        } label: {
            MKeyIconCap(symbol: "magnifyingglass", active: controller.search.isPresented)
        }
        .buttonStyle(MPressStyle())
        .accessibilityLabel("查找")
    }

    /// 上膛之后多半是要接着在系统键盘上打一个字符（Ctrl+C），所以顺手把键盘弹出来；接着点键盘条上的键也行（Ctrl+←）。
    private func modifierKey(_ label: String, armed: Bool, toggle: @escaping () -> Void) -> some View {
        MKeyButton(label: label, active: armed) {
            toggle()
            if !armed { controller.showKeyboard() }
        }
    }

    private func keyButtons(_ keys: [TerminalKey]) -> some View {
        ForEach(keys) { key in
            MKeyButton(label: key.label) { send(key) }
        }
    }

    /// 贴图片：剪贴板里的图，或相册里选一张。直连服务器传成 `/tmp` 下的文件并粘上路径；
    /// Mac 本机终端放进 Mac 剪贴板再按 Ctrl+V（Claude Code 等从剪贴板读图）。
    private var imageMenu: some View {
        MMenu {
            Button {
                controller.sendImage { try await RemoteDesktopPasteSource.clipboardImage() }
            } label: { Label("粘贴剪贴板里的图片", systemImage: "doc.on.clipboard") }
            Button { pickingPhoto = true } label: { Label("从相册选择…", systemImage: "photo.on.rectangle") }
        } label: {
            MKeyIconCap(symbol: "photo")
        }
        .accessibilityLabel("粘贴图片")
    }

    /// 发送一个键。上膛的 Ctrl / Alt 作用在这个键上（Ctrl 上膛后点 ← 发 Ctrl+←），用完自己复位。
    private func send(_ key: TerminalKey) {
        controller.sendKey(key)
    }

    // MARK: 面板

    @ViewBuilder private func panelContent(_ panel: Panel) -> some View {
        switch panel {
        case .prompts:
            MKeyBarAIPanel(phrases: TerminalPhrases.decode(phrasesRaw), agentInForeground: agentInForeground,
                           submit: submit, fill: fill, edit: { editingPhrases = true }) {
                keySection("选项与模式", TerminalKeyCatalog.agentKeys)
            }
        case .keys:
            keySection("导航", TerminalKeyCatalog.navigation)
            keySection("Ctrl", TerminalKeyCatalog.control)
            keySection("功能键", TerminalKeyCatalog.function)
            keySection("符号", TerminalKeyCatalog.symbols)
        }
    }

    private func keySection(_ title: LocalizedStringKey, _ keys: [TerminalKey]) -> some View {
        MKeyGridSection(title: title, keys: keys, label: \.label, action: send)
    }

    /// 发完收起面板、不弹键盘：接下来是看 AI 输出。启动命令同样走这里（括号粘贴 + 隔一下回车，shell 照样认）。
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

/// 浮在键盘条上方的一条提示（贴图的进度 / 结果），进行中时字下面带一条进度条。它压在终端的字上面，底必须不透明：`M.button` 只是一层
/// 白 8% / 黑 4% 的淡色，单用它字会从下面透上来（1090 实测）。所以先垫工作面的底色，再叠键帽那层淡色，
/// 外加一圈分区线把它和同色的终端分开。
struct MKeyBarNote: View {
    let text: String
    /// 0...1；nil = 不带进度条。
    var progress: Double?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: MRadius.sm)
        VStack(alignment: .leading, spacing: 5) {
            Text(text)
                .font(M.sans(12, weight: .medium))
                .foregroundStyle(M.text)
                .lineLimit(2)
            if let progress {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(M.accent)
                    .frame(width: 180)
                    .accessibilityLabel(text)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(M.button)
        .background(M.surface)
        .clipShape(shape)
        .overlay(shape.strokeBorder(M.divider, lineWidth: 1))
    }
}

