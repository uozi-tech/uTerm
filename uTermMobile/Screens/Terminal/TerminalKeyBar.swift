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

/// 终端的快捷键条：外壳与键帽见 `MKeyBar`（远程桌面共用），这里只管发什么给终端。
struct TerminalKeyBar: View {
    enum Panel: Hashable { case prompts, keys }

    let controller: MobileTerminalController
    @State private var panel: Panel?
    @State private var panels = MKeyBarPanelSwitch<Panel>()
    @State private var softKeyboardUp = false
    @State private var pickingPhoto = false
    @State private var pickedPhoto: PhotosPickerItem?

    /// `panel` 的初值。生产侧一律省略（收起），探针和样式画廊用它把面板也挂起来。
    init(controller: MobileTerminalController, panel: Panel? = nil) {
        self.controller = controller
        _panel = State(initialValue: panel)
    }

    var body: some View {
        MKeyBar(panel: $panel, softKeyboardUp: $softKeyboardUp) {
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
            controller.sendImage {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    throw RemoteDesktopPasteSource.Failure.unreadableImage
                }
                return try await RemoteDesktopPasteSource.terminalImage(data: data)
            }
        }
    }

    private func toggle(_ target: Panel) {
        panels.toggle(target, panel: &panel, softKeyboardUp: softKeyboardUp,
                      showKeyboard: controller.showKeyboard, collapseKeyboard: controller.collapseKeyboard)
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

    @ViewBuilder private var keyRow: some View {
        MKeyBarPanelButton(symbol: "square.grid.2x2", label: "更多按键", active: panel == .keys) { toggle(.keys) }
        MKeyBarPanelButton(symbol: "text.bubble", label: "AI 提示词", active: panel == .prompts) { toggle(.prompts) }
        MKeyBarGap()
        modifierKey("ctrl", armed: controller.controlArmed) { controller.toggleControl() }
        modifierKey("alt", armed: controller.altArmed) { controller.toggleAlt() }
        if controller.acceptsImages { imageMenu }
        MKeyBarGap()
        keyButtons(TerminalKeyCatalog.primary)
        MKeyBarGap()
        ForEach(TerminalKeyCatalog.arrows) { key in
            MRepeatingKeyButton(label: key.label) { send(key) }
        }
        MKeyBarGap()
        keyButtons(TerminalKeyCatalog.shellSymbols)
    }

    /// 粘滞修饰只作用于系统键盘的下一个字符，所以上膛时键盘必须在。
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

    /// 发送一个键：先清掉粘滞修饰（修饰只作用于系统软键盘字符），再发字节序列。
    private func send(_ key: TerminalKey) {
        controller.clearStickyModifiers()
        controller.sendText(key.send)
    }

    // MARK: 面板

    @ViewBuilder private func panelContent(_ panel: Panel) -> some View {
        switch panel {
        case .prompts:
            keySection("选项与模式", TerminalKeyCatalog.agentKeys)
            MPromptGridSection(title: "提示词", prompts: TerminalKeyCatalog.prompts, minWidth: 150, mono: false,
                               submit: submit, fill: fill)
            MPromptGridSection(title: "斜杠命令", prompts: TerminalKeyCatalog.slashCommands, minWidth: 92, mono: true,
                               submit: submit, fill: fill)
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
