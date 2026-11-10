import SwiftUI

/// 远程桌面键盘条上的一个键：Mac 键码 + 这个键自带的修饰（⇧Tab 的 ⇧）。
nonisolated struct RemoteBarKey: Identifiable, Hashable {
    let label: String
    let code: UInt16
    var modifiers: RemoteKeyModifiers = []
    var id: String { label }
}

/// 远程桌面键盘条的键。分组、顺序与终端的 `TerminalKeyCatalog` 对齐，换成 Mac 的键。
enum RemoteKeyCatalog {
    static let modifiers: [(label: String, modifier: RemoteKeyModifiers)] = [
        ("⌃", .control), ("⌥", .option), ("⇧", .shift), ("⌘", .command),
    ]
    static let escape = RemoteBarKey(label: "esc", code: RemoteKeyMap.Key.escape)
    static let enter = RemoteBarKey(label: "↵", code: RemoteKeyMap.Key.returnKey)
    static let shiftTab = RemoteBarKey(label: "⇧Tab", code: RemoteKeyMap.Key.tab, modifiers: .shift)

    static let primary = [escape, RemoteBarKey(label: "tab", code: RemoteKeyMap.Key.tab), enter]
    /// 方向键和删除长按连发。
    static let repeating = [
        RemoteBarKey(label: "←", code: RemoteKeyMap.Key.left), RemoteBarKey(label: "↑", code: RemoteKeyMap.Key.up),
        RemoteBarKey(label: "↓", code: RemoteKeyMap.Key.down), RemoteBarKey(label: "→", code: RemoteKeyMap.Key.right),
        RemoteBarKey(label: "⌫", code: RemoteKeyMap.Key.delete),
    ]
    static let space = RemoteBarKey(label: "space", code: RemoteKeyMap.Key.space)

    static let navigation = [
        RemoteBarKey(label: "home", code: RemoteKeyMap.Key.home), RemoteBarKey(label: "end", code: RemoteKeyMap.Key.end),
        RemoteBarKey(label: "pgUp", code: RemoteKeyMap.Key.pageUp),
        RemoteBarKey(label: "pgDn", code: RemoteKeyMap.Key.pageDown),
        RemoteBarKey(label: "del", code: RemoteKeyMap.Key.forwardDelete), shiftTab,
    ]
    static let function = RemoteKeyMap.Key.function.enumerated().map {
        RemoteBarKey(label: "F\($0.offset + 1)", code: $0.element)
    }
    /// 符号与数字按物理键发（要 ⇧ 的自己带上），和英文键盘打出来的一样交给 Mac 当前的输入法。
    static let symbols = TerminalKeyCatalog.symbols.compactMap { characterKey($0.label) }
    /// AI 命令行里的选择题和模式切换，同终端那一组。
    static let agentKeys = ["1", "2", "3"].compactMap { characterKey($0) } + [enter, escape, shiftTab]

    static func characterKey(_ text: String) -> RemoteBarKey? {
        guard let character = text.first, let mapped = RemoteKeyMap.keyCode(for: character) else { return nil }
        return RemoteBarKey(label: text, code: mapped.code, modifiers: mapped.shift ? .shift : [])
    }
}

/// 远程桌面的键盘条：外壳、键帽、面板与终端的 `TerminalKeyBar` 共用（`MKeyBar`），发的是 Mac 键码。
///
/// 修饰键（⌃⌥⇧⌘）是粘滞的，作用于下一次按键**或点击**（⌘ 点击多选），所以上膛时不弹键盘。
/// 提示词按 Unicode 文字注入，不经 Mac 的输入法；回车隔一下单独发（见 `MobileTerminalController.submitPrompt`）。
struct RemoteDesktopKeyBar: View {
    enum Panel: Hashable { case prompts, keys }

    let keys: RemoteDesktopKeyState
    /// 系统键盘弹着。由画布执行（`RemoteDesktopCanvas`），系统收走键盘时它会写回 false。
    @Binding var keyboardShown: Bool
    let send: (RemoteDesktopInput) -> Void
    @State private var panel: Panel?
    @State private var panels = MKeyBarPanelSwitch<Panel>()
    @State private var softKeyboardUp = false

    init(keys: RemoteDesktopKeyState, keyboardShown: Binding<Bool>, panel: Panel? = nil,
         send: @escaping (RemoteDesktopInput) -> Void) {
        self.keys = keys
        _keyboardShown = keyboardShown
        _panel = State(initialValue: panel)
        self.send = send
    }

    var body: some View {
        MKeyBar(panel: $panel, softKeyboardUp: $softKeyboardUp) {
            MKeyBarPanelButton(symbol: "square.grid.2x2", label: "更多按键", active: panel == .keys) { toggle(.keys) }
            MKeyBarPanelButton(symbol: "text.bubble", label: "AI 提示词", active: panel == .prompts) { toggle(.prompts) }
            MKeyBarGap()
            ForEach(RemoteKeyCatalog.modifiers, id: \.label) { item in
                MKeyButton(label: item.label, active: keys.modifiers.contains(item.modifier)) {
                    keys.toggle(item.modifier)
                }
            }
            MKeyBarGap()
            ForEach(RemoteKeyCatalog.primary) { key in MKeyButton(label: key.label) { tap(key) } }
            MKeyBarGap()
            ForEach(RemoteKeyCatalog.repeating) { key in MRepeatingKeyButton(label: key.label) { tap(key) } }
            MKeyBarGap()
            MKeyButton(label: RemoteKeyCatalog.space.label) { tap(RemoteKeyCatalog.space) }
        } trailing: {
            MKeyBarKeyboardButton(shown: keyboardShown) { keyboardShown.toggle() }
        } content: { panel in
            switch panel {
            case .prompts:
                section("选项与模式", RemoteKeyCatalog.agentKeys)
                MPromptGridSection(title: "提示词", prompts: TerminalKeyCatalog.prompts, minWidth: 150, mono: false,
                                   submit: submit, fill: fill)
                MPromptGridSection(title: "斜杠命令", prompts: TerminalKeyCatalog.slashCommands, minWidth: 92,
                                   mono: true, submit: submit, fill: fill)
            case .keys:
                section("导航", RemoteKeyCatalog.navigation)
                section("功能键", RemoteKeyCatalog.function)
                section("符号", RemoteKeyCatalog.symbols)
            }
        }
    }

    private func section(_ title: LocalizedStringKey, _ keys: [RemoteBarKey]) -> some View {
        MKeyGridSection(title: title, keys: keys, label: \.label, action: tap)
    }

    private func toggle(_ target: Panel) {
        panels.toggle(target, panel: &panel, softKeyboardUp: softKeyboardUp,
                      showKeyboard: { keyboardShown = true }, collapseKeyboard: { keyboardShown = false })
    }

    /// 按一下：带上这个键自带的和上膛的修饰（然后熄灭），按下再抬起。
    private func tap(_ key: RemoteBarKey) {
        for input in Self.press(key, armed: keys.consume()) { send(input) }
    }

    nonisolated static func press(_ key: RemoteBarKey, armed: RemoteKeyModifiers) -> [RemoteDesktopInput] {
        let modifiers = armed.union(key.modifiers)
        return [.key(code: key.code, down: true, modifiers: modifiers),
                .key(code: key.code, down: false, modifiers: modifiers)]
    }

    /// 发完收起面板、不弹键盘：接下来是看 AI 输出。
    private func submit(_ prompt: String) {
        panel = nil
        _ = keys.consume()
        send(.text(prompt))
        Task {
            try? await Task.sleep(for: AgentPromptSubmit.enterDelay)
            for input in Self.press(RemoteKeyCatalog.enter, armed: []) { send(input) }
        }
    }

    /// 只填入：接下来要接着打字，键盘弹出来（键盘回来时面板会自己让位）。
    private func fill(_ prompt: String) {
        panel = nil
        _ = keys.consume()
        send(.text(prompt))
        keyboardShown = true
    }
}
