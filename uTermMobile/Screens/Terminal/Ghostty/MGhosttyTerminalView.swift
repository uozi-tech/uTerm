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
    /// 剪贴板里只有图片时的粘贴交给宿主（传到远端再把路径粘进来）。
    var onPasteImage: (() -> Void)?
    /// 是否已按真实窗格排布过。首次排布立即生效（此时还没有程序在画），之后的变化都要等停稳，见 `MTerminalContainerView`。
    var hasHostedLayout = false

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

    /// 用户在这个终端里切到的输入法；nil = 还没切过，用英文。每个标签各记各的。
    private var chosenInputMode: UITextInputMode?
    private var observesInputMode = false

    /// 系统在终端成为第一响应者时按它挑键盘。命令行默认要英文；用户用地球键切走（中文写提交说明、跟 Claude Code 说话）
    /// 之后，回到这个终端还是用户选的那个。
    override var textInputMode: UITextInputMode? {
        chosenInputMode ?? Self.englishInputMode ?? super.textInputMode
    }

    private static var englishInputMode: UITextInputMode? {
        UITextInputMode.activeInputModes.first { $0.primaryLanguage?.hasPrefix("en") == true }
    }

    @discardableResult
    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFocusChanged?(true) }
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
        if resigned { onFocusChanged?(false) }
        return resigned
    }

    @objc private func inputModeDidChange() {
        // 只记自己是第一响应者时的切换：别的标签抢到键盘时系统把键盘换成英文，那不是用户在这里选的。
        guard isFirstResponder, let mode = super.textInputMode else { return }
        chosenInputMode = mode
    }

    // MARK: 粘贴：剪贴板里只有图片时当贴图

    override func paste(_ sender: Any?) {
        let board = UIPasteboard.general
        // GhosttyKit 自己的做法是把图片存成本机文件、粘本机路径，对远端的程序没用，所以整个接走。
        if !board.hasStrings, board.hasImages {
            onPasteImage?()
            return
        }
        super.paste(sender)
    }
}
