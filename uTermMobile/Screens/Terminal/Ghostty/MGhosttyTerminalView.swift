import GhosttyTerminal
import UIKit

// 命名：GhosttyTerminal 也导出了 `TerminalKey` / `TerminalColorScheme` / `TerminalController` / `TerminalTheme`，
// 本模块里同名的 uTerm 类型优先，所以 GhosttyKit 的一律写全 `GhosttyTerminal.`。

/// iOS 的终端视图：GhosttyKit 的 `UITerminalView` 加上 uTerm 的输入与键盘策略。全部是子类覆写，不改包里的实现。
final class MGhosttyTerminalView: UITerminalView {
    /// 只有轮到自己的会话才肯拿键盘。光在我们自己的聚焦调用里设卡不够：UIKit 收起抽屉 / 弹层时会把之前的第一响应者
    /// 自动恢复回来，不经过任何我们的代码——第一个标签已连上、第二个标签正在建连时，键盘就是这样冒出来的。
    /// nil = 不拦（探针用）。
    var canTakeKeyboard: (() -> Bool)?
    /// 第一响应者变化（宿主据此同步「键盘在不在这个会话上」）。
    var onFocusChanged: ((Bool) -> Void)?
    /// 第一响应者变化，给开了 DEC 1004 的程序报 focus in / out 用（`GhosttyTerminalBridge` 接）。surface 一直聚焦，引擎不报。
    var onFocusReport: ((Bool) -> Void)?
    /// 剪贴板里只有图片 / 视频时的粘贴交给宿主（传到远端再把路径粘进来）。
    var onPasteMedia: (() -> Void)?
    /// 选中的文字是路径或网址时，编辑菜单第一项「打开」交给宿主（`TerminalLinkDetector`）。nil = 不加这一项。
    var onOpenLink: ((String) -> Void)?
    /// 这个链接点了会不会有反应（远控镜像里的路径不会）；没有反应就不加「打开」。
    var canOpenLink: ((String) -> Bool)?
    /// 是否已按真实窗格排布过。首次排布立即生效（此时还没有程序在画），之后的变化都要等停稳，见 `MTerminalContainerView`。
    var hasHostedLayout = false
    /// 这片终端的回滚区查找（`TerminalSurfaceLink.search`）：硬件键盘的 ⌘F / ⌘G / ⇧⌘G 落到它上面。
    weak var search: TerminalSearch?

    override init(frame: CGRect) {
        super.init(frame: frame)
        // uTerm 的字号跟着窗格宽度走（`TerminalSessionBody.adaptiveFontSize`），捏合缩放改的字号下一次宽度变化就会被盖掉，
        // 干脆不接这个手势。
        gestureRecognizers?.compactMap { $0 as? UIPinchGestureRecognizer }.forEach { $0.isEnabled = false }
        // 用 uTerm 自己的 `TerminalKeyBar`，不要 GhosttyKit 自带的按键辅助条（两层会叠在键盘上方）。
        inputAccessoryItems = []
    }

    override var canBecomeFirstResponder: Bool { canTakeKeyboard?() ?? true }

    // MARK: 字号

    /// 当前字号（uTerm 的点数，和 `UIFont` 同一个口径）。
    private(set) var terminalFontSize: CGFloat = MGhosttyTerminalView.defaultFontSize
    nonisolated static let defaultFontSize: CGFloat = 11

    /// Ghostty 的 `font-size` 在 iOS 上按 96 dpi 换算（实测 11 → 格子 8.93×19.49pt，11pt SF Mono 该是 6.78×14.07pt，
    /// 宽高都差 ≈4/3）。要和 `UIFont` 的点数一样大，传 points × 72/96。
    nonisolated static func ghosttyFontSize(points: CGFloat) -> Float {
        Float(points * 72 / 96)
    }

    /// 换字号。有 surface 时当场生效（格子变了，网格跟着重算）；没有时记下来，建 surface 时用它。
    func setTerminalFontSize(_ points: CGFloat) {
        guard abs(points - terminalFontSize) > 0.01 else { return }
        terminalFontSize = points
        let size = Self.ghosttyFontSize(points: points)
        if surface != nil {
            uTermSetFontSize(size)
        } else {
            configuration.fontSize = size
        }
    }

    /// surface 重建时从 `configuration.fontSize` 起步；有 surface 期间的字号变化走的是 binding，没写回配置
    ///（写回会让 GhosttyKit 重建 surface）。放掉 surface 之后把配置对齐到当前字号，重建出来的才是对的。
    func alignConfiguredFontSize() {
        guard surface == nil else { return }
        configuration.fontSize = Self.ghosttyFontSize(points: terminalFontSize)
    }

    // MARK: 键盘：点终端只弹出、不收起

    /// GhosttyKit 默认点一下终端在弹出 / 收起之间切。uTerm 收起键盘走键盘条上的按钮，点终端一律是「要回键盘」
    ///（同换引擎之前）：看输出时手指碰一下屏幕不该把键盘收走。
    override func toggleSoftwareKeyboard() {
        if !isFirstResponder { becomeFirstResponder() }
    }

    // MARK: 键盘类型可写（上游 getter 恒为 .default、setter 是空实现）

    /// 普通键盘：用户能用地球键切到中文等输入法（`.asciiCapable` 只能在 ASCII 键盘间切）。「默认英文」由下面的
    /// `textInputMode` 负责。
    var preferredKeyboardType: UIKeyboardType = .default {
        didSet { if isFirstResponder { reloadInputViews() } }
    }

    override var keyboardType: UIKeyboardType {
        get { preferredKeyboardType }
        set { preferredKeyboardType = newValue }
    }

    // MARK: 输入法：默认英文，用户切了就记住

    private var observesInputMode = false

    /// 系统在终端成为第一响应者时按它挑键盘。命令行默认要英文；用户用地球键切走（中文写提交说明、跟 Claude Code 说话）
    /// 之后，所有终端都用他选的那个，重开 App 也是（`KeyboardLanguageMemory`）。
    override var textInputMode: UITextInputMode? {
        KeyboardLanguageMemory.terminal.inputMode(current: super.textInputMode)
    }

    @discardableResult
    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became {
            onFocusReport?(true)
            onFocusChanged?(true)
        }
        if became, !observesInputMode {
            observesInputMode = true
            NotificationCenter.default.addObserver(self, selector: #selector(inputModeDidChange),
                                                   name: UITextInputMode.currentInputModeDidChangeNotification,
                                                   object: nil)
        }
        return became
    }

    @discardableResult
    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            onFocusReport?(false)
            onFocusChanged?(false)
        }
        return resigned
    }

    @objc private func inputModeDidChange() {
        // 只记自己是第一响应者时的切换：别处抢到键盘时系统换的键盘，不是用户在这里选的。
        guard isFirstResponder else { return }
        KeyboardLanguageMemory.terminal.record(super.textInputMode)
    }

    // MARK: 硬件键盘的查找键

    /// ⌘F 打开查找栏，⌘G / ⇧⌘G 往上 / 往下找（同 Mac）。按键绑定表里清掉了 Ghostty 自己的 ⌘F，这几个组合不会发给程序。
    override var keyCommands: [UIKeyCommand]? {
        var commands = super.keyCommands ?? []
        guard search != nil else { return commands }
        commands += Self.findKeyCommands
        return commands
    }

    private static let findKeyCommands: [UIKeyCommand] = [
        findKeyCommand(String(localized: "查找"), input: "f", modifiers: .command, action: #selector(showTerminalFind)),
        findKeyCommand(String(localized: "往上找"), input: "g", modifiers: .command, action: #selector(terminalFindNext)),
        findKeyCommand(String(localized: "往下找"), input: "g", modifiers: [.command, .shift],
                       action: #selector(terminalFindPrevious)),
    ]

    private static func findKeyCommand(_ title: String, input: String, modifiers: UIKeyModifierFlags,
                                       action: Selector) -> UIKeyCommand {
        let command = UIKeyCommand(title: title, action: action, input: input, modifierFlags: modifiers)
        command.wantsPriorityOverSystemBehavior = true
        return command
    }

    @objc private func showTerminalFind() { search?.present() }
    @objc private func terminalFindNext() { search?.next() }
    @objc private func terminalFindPrevious() { search?.previous() }

    // MARK: 选中路径 / 网址时的「打开」

    /// 手机上没有 ⌘ 点：双击（或长按、三击）选中路径或网址，菜单第一项是「打开」。
    /// 网址另外可以直接点开（libghostty-spm 2.2.2026112401 起：单指点 http / https 链接就交给 `terminalDidRequestOpenURL`，
    /// 不弹键盘）；路径仍然只走这里。
    override func touchSelectionMenuItems(for context: TerminalTouchSelectionMenuContext) -> [UIMenuElement] {
        let upstream = super.touchSelectionMenuItems(for: context)
        guard let onOpenLink, let link = TerminalLinkDetector.link(inSelection: context.selectedText) else { return upstream }
        // 引擎认出手指下是链接时，上游自己也放一项「Open Link」（`terminal.openLink`，libghostty-spm 2.2.2026112401 起）。
        // 选中的就是一条链接时由我们说了算：能开就放我们带名字的那项（判断规则两端共用），不能开（远控镜像里的路径、
        // 不认的 scheme）就两项都不放——上游那项点了也是交给 `openTerminalLink`，什么都不会发生。
        let items = upstream.filter { ($0 as? UIAction)?.identifier.rawValue != "terminal.openLink" }
        guard canOpenLink?(link) ?? true else { return items }
        let title: String
        if case .web = TerminalLink.classify(link) {
            title = String(localized: "打开「\(TerminalLinkDetector.displayName(of: link))」",
                           comment: "终端选中网址后编辑菜单里的一项：交给浏览器打开；插值是网址的主机名")
        } else {
            title = String(localized: "在 uTerm 中打开「\(TerminalLinkDetector.displayName(of: link))」",
                           comment: "终端选中路径后编辑菜单里的一项：在旁边的预览标签里打开；插值是文件名")
        }
        let open = UIAction(title: title, image: UIImage(systemName: "arrow.up.forward.square"),
                            identifier: UIAction.Identifier("uterm.openLink")) { [weak self] _ in
            _ = self?.uTermClearSelection(onlyIfBlank: false)
            onOpenLink(link)
        }
        return [open] + items
    }

    // MARK: 粘贴：剪贴板里只有图片 / 视频时当贴图片 / 视频

    override func paste(_ sender: Any?) {
        let board = UIPasteboard.general
        // GhosttyKit 自己的做法是把图片存成本机文件、粘本机路径，对远端的程序没用，所以整个接走。
        if !board.hasStrings, board.hasImages || TerminalPasteSource.hasVideo(board) {
            onPasteMedia?()
            return
        }
        super.paste(sender)
    }
}
