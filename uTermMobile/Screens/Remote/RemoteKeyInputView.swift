import GhosttyTerminal
import UIKit

/// 手机键盘打出来的东西怎么发给 Mac。
///
/// - 手机是英文键盘：字母、数字、符号发成**按键**，由 Mac 当前的输入法处理（Mac 开着拼音就在 Mac 上出候选）。
/// - 手机切到别的语言：在手机上组字、选词，上屏结果按 **Unicode** 注入。这种事件不经过 Mac 的输入法，
///   Mac 开着拼音也不会被截走（搜狗、微信输入法实测，含 `hello`、`123` 这样的纯 ASCII），Mac 上那个
///   远程看不清的候选框也就不会出现。
nonisolated enum RemoteKeyboardRouting {
    /// 这个键盘语言的字要不要发成按键。拿不到语言时按英文算，与之前的行为一致。
    static func usesKeyPresses(language: String?) -> Bool {
        language?.hasPrefix("en") ?? true
    }

    /// 一段文字对应的输入。上膛的修饰键只作用于第一个字符（⌘C、⌃A……），这个字符一律发成按键。
    /// 换行和单独一个空格也发按键：它们是回车确认、空格预览这样的操作，不是要打出来的字。
    static func inputs(for text: String, armed: RemoteKeyModifiers, asKeys: Bool) -> [RemoteDesktopInput] {
        var result: [RemoteDesktopInput] = []
        var pending = ""
        var modifiers = armed

        func flush() {
            guard !pending.isEmpty else { return }
            result.append(.text(pending))
            pending = ""
        }
        func tap(_ code: UInt16, _ modifiers: RemoteKeyModifiers) {
            flush()
            result.append(.key(code: code, down: true, modifiers: modifiers))
            result.append(.key(code: code, down: false, modifiers: modifiers))
        }

        for character in text {
            let pressesKey = asKeys || !modifiers.isEmpty || character == "\t" || text == " "
            if character.isNewline {
                tap(RemoteKeyMap.Key.returnKey, modifiers)
            } else if pressesKey, let mapped = RemoteKeyMap.keyCode(for: character) {
                tap(mapped.code, mapped.shift ? modifiers.union(.shift) : modifiers)
            } else {
                pending.append(character)
            }
            modifiers = []
        }
        flush()
        return result
    }

    /// 外接键盘的这一键要不要留给手机的输入法。组字中全部留给它（方向键选词、回车上屏）；
    /// 没在组字时，手机选了别的语言才留，且只留能打出字的键。带 ⌘⌃⌥ 或键盘条上膛的是快捷键，发给 Mac。
    static func leavesToSystem(hidUsage: Int, flags: UIKeyModifierFlags, armed: Bool, composing: Bool,
                               asKeys: Bool) -> Bool {
        if composing { return true }
        if asKeys || armed || !flags.isDisjoint(with: [.command, .control, .alternate]) { return false }
        return (0x04...0x27).contains(hidUsage) || (0x2C...0x38).contains(hidUsage)
    }
}

/// 隐藏的文字输入：弹软键盘、收字、组字。外接键盘的物理按键也在这里翻成 Mac 键码。
///
/// 发法见 `RemoteKeyboardRouting`。文档内容是正在组的字，前面加上听写还可能改写的那段已上屏的字
///（`TerminalCommittedTail`，同终端）：流式听写每出一版结果都要在文档里找到上一版再换掉，找不到就取消，
/// 原来手机这边一个字都不留，听写每说一个词就停。别的按键、上膛的快捷键、外接键盘、收起键盘都清掉那一段。
/// 视图铺在画布底边显示组字内容，不接触摸，候选框（iPad 的浮动候选）也贴着它。
@MainActor
final class RemoteKeyInputView: UIView, UITextInput {
    static let languageKey = DefaultsKey.remoteDesktopKeyboardLanguage

    var keys: RemoteDesktopKeyState?
    var send: ((RemoteDesktopInput) -> Void)?
    /// 用户或系统收起了键盘。外面自己调 `dismissKeyboard()` 时不回调。
    var onResign: (() -> Void)?
    /// 系统键盘自带的「粘贴」（候选栏上的粘贴、编辑菜单）。系统只是对第一响应者发一个 `paste:`，不往里塞字；
    /// 以前没接，点了没有任何反应（2026-11-18 user）。交给外面按「粘贴到 Mac」处理（文字、图片、视频都行）。
    var onPaste: (() -> Void)?

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(UIResponderStandardEditActions.paste(_:)) { return onPaste != nil }
        return super.canPerformAction(action, withSender: sender)
    }

    override func paste(_ sender: Any?) {
        onPaste?()
    }
    /// 只给测试用：模拟器里切不了真实键盘。
    var languageOverride: String?
    /// 键盘触控板（长按空格键滑动）移动什么。没接 `movePointer` 时一律移动文字光标。
    var trackpadMode: RemoteKeyboardTrackpadMode = .defaultValue
    /// 键盘触控板在「移动鼠标指针」时交出的位移与速度（点 / 秒）。
    var movePointer: ((CGSize, CGFloat) -> Void)?

    private var composition: String?
    /// 组字里的选区（组字内的偏移）。
    private var selection = NSRange(location: 0, length: 0)
    /// 听写还可能改写的那段已上屏的字，文档里排在组字前面。
    private var tail = TerminalCommittedTail()
    /// 正在把那一段的改写发给 Mac：这期间的按键是自己发的，不清那一段。
    private var applyingTailEdit = false
    private var dismissing = false
    private var observesInputMode = false
    /// 按下时留给系统的外接键盘按键，抬起也要交给系统，否则系统那边这个键一直按着。
    private var keysLeftToSystem: Set<Int> = []
    /// 正按着的键盘触控板，以及它这一次走的是哪种。组字时按下的不归我们管（交给输入法移动组字里的光标）。
    private var floating: (trackpad: RemoteKeyboardTrackpad, mode: RemoteKeyboardTrackpadMode)?
    /// 这一次触控板已经按过方向键：松手时才取走键盘条上膛的修饰键。
    private var floatingSentArrows = false
    private let compositionLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        TerminalDictationInput.startObserving()
        compositionLabel.isHidden = true
        compositionLabel.textAlignment = .center
        compositionLabel.backgroundColor = UIColor.black.withAlphaComponent(0.8)
        compositionLabel.layer.cornerRadius = 8
        compositionLabel.layer.masksToBounds = true
        addSubview(compositionLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var canBecomeFirstResponder: Bool { true }

    /// 关掉系统的三指编辑手势（三指左右扫 = 撤销 / 重做、捏合 = 拷贝粘贴）：键盘弹着时它会抢走画布上的
    /// 三指扫动（切换桌面），还会弹出撤销的提示。远程桌面里撤销用 ⌘Z。
    override var editingInteractionConfiguration: UIEditingInteractionConfiguration { .none }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool { false }

    // 远程桌面里自动更正、自动大写、智能标点都只会帮倒忙。
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    /// 普通键盘：地球键能切到中文等（`.asciiCapable` 只能在 ASCII 键盘间切）。默认语言见 `textInputMode`。
    var keyboardType: UIKeyboardType = .default
    var returnKeyType: UIReturnKeyType = .default

    // MARK: - 键盘语言：默认英文，切过就记住

    override var textInputMode: UITextInputMode? {
        KeyboardLanguageMemory.remoteDesktop.inputMode(current: super.textInputMode)
    }

    private var sendsKeyPresses: Bool {
        RemoteKeyboardRouting.usesKeyPresses(language: languageOverride ?? super.textInputMode?.primaryLanguage)
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became, !observesInputMode {
            observesInputMode = true
            NotificationCenter.default.addObserver(self, selector: #selector(inputModeDidChange),
                                                   name: UITextInputMode.currentInputModeDidChangeNotification,
                                                   object: nil)
        }
        return became
    }

    @objc private func inputModeDidChange() {
        // 只记自己是第一响应者时的切换：别处抢到键盘时系统换的语言，不是用户在这里选的。
        guard isFirstResponder else { return }
        KeyboardLanguageMemory.remoteDesktop.record(super.textInputMode)
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        guard resigned else { return false }
        if composition != nil { clearComposition() }
        resetTail()
        if !dismissing { onResign?() }
        return true
    }

    /// 由外面的键盘按钮收起：外面已经知道了，不再回调。这条路在 SwiftUI 更新视图期间走，
    /// 回调里写状态就是「Modifying state during view update」。
    func dismissKeyboard() {
        dismissing = true
        defer { dismissing = false }
        _ = resignFirstResponder()
    }

    // MARK: - 收字

    var hasText: Bool { true }

    func insertText(_ text: String) {
        if composition != nil {
            // 输入法上屏，替换掉正在组的字。修饰键留给下一次按键。
            setComposition(nil, selectedRange: NSRange(location: 0, length: 0))
            commit(text, armed: [], asKeys: false)
        } else {
            commit(text, armed: keys?.consume() ?? [], asKeys: sendsKeyPresses)
        }
    }

    /// 上屏一段字。留着听写那一段时接在它后面；带上膛修饰的是快捷键，那一段作废。
    /// 听写的第一版也从这里进来（UIKit 在光标处插入时调 `insertText`，见 `TerminalDictationInput`），从它开始记。
    private func commit(_ text: String, armed: RemoteKeyModifiers, asKeys: Bool) {
        let isHypothesis = TerminalDictationInput.claimHypothesis()
        guard !tail.isEmpty || isHypothesis, armed.isEmpty else {
            resetTail()
            deliver(text, armed: armed, asKeys: asKeys)
            return
        }
        applyTailEdit { deliver(text, armed: [], asKeys: asKeys) }
        if text.contains(where: \.isNewline) { tail.clear() } else { tail.append(text) }
    }

    func deleteBackward() {
        if var composing = composition {
            composing.removeLast()
            let length = composing.utf16.count
            setComposition(composing.isEmpty ? nil : composing, selectedRange: NSRange(location: length, length: 0))
            return
        }
        let modifiers = keys?.consume() ?? []
        guard modifiers.isEmpty, tail.removeLast() else {
            tap(RemoteKeyMap.Key.delete, modifiers: modifiers)
            return
        }
        applyTailEdit { tap(RemoteKeyMap.Key.delete, modifiers: []) }
    }

    func tap(_ code: UInt16, modifiers: RemoteKeyModifiers) {
        resetTail()
        send?(.key(code: code, down: true, modifiers: modifiers))
        send?(.key(code: code, down: false, modifiers: modifiers))
    }

    private func applyTailEdit(_ body: () -> Void) {
        let was = applyingTailEdit
        applyingTailEdit = true
        defer { applyingTailEdit = was }
        body()
    }

    /// Mac 上那一行被别的输入改了：清掉听写那一段。听写进行中清掉会让系统取消这次听写——用户确实做了别的事。
    private func resetTail() {
        guard !applyingTailEdit, !tail.isEmpty else { return }
        inputDelegate?.textWillChange(self)
        inputDelegate?.selectionWillChange(self)
        tail.clear()
        inputDelegate?.selectionDidChange(self)
        inputDelegate?.textDidChange(self)
    }

    private func deliver(_ text: String, armed: RemoteKeyModifiers, asKeys: Bool) {
        for input in RemoteKeyboardRouting.inputs(for: text, armed: armed, asKeys: asKeys) { send?(input) }
    }

    // MARK: - 组字

    var markedTextRange: UITextRange? {
        composition.map { RemoteTextRange(tail.length, tail.length + $0.utf16.count) }
    }
    var markedTextStyle: [NSAttributedString.Key: Any]?

    func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
        // 中文键盘上按键条上膛的 ⌘ + C：这一键是快捷键，不是开始拼字。
        if composition == nil, let keys, !keys.modifiers.isEmpty,
           let first = markedText?.first, RemoteKeyMap.keyCode(for: first) != nil {
            resetTail()
            deliver(String(first), armed: keys.consume(), asKeys: true)
            clearComposition()
            return
        }
        setComposition(markedText?.isEmpty == false ? markedText : nil, selectedRange: selectedRange)
    }

    /// 输入法要求把正在组的字原样定下来（比如拼音键盘上按回车上屏字母）。
    func unmarkText() {
        guard let text = composition else { return }
        setComposition(nil, selectedRange: NSRange(location: 0, length: 0))
        commit(text, armed: [], asKeys: false)
    }

    private func setComposition(_ text: String?, selectedRange: NSRange) {
        composition = text
        let length = text?.utf16.count ?? 0
        let location = min(max(selectedRange.location, 0), length)
        selection = NSRange(location: location, length: min(max(selectedRange.length, 0), length - location))
        updateCompositionLabel()
    }

    /// 由我们这边丢弃组字：要告诉输入系统，它才会清掉自己的候选。
    private func clearComposition() {
        inputDelegate?.selectionWillChange(self)
        inputDelegate?.textWillChange(self)
        setComposition(nil, selectedRange: NSRange(location: 0, length: 0))
        inputDelegate?.textDidChange(self)
        inputDelegate?.selectionDidChange(self)
    }

    private func updateCompositionLabel() {
        guard let composition else {
            compositionLabel.isHidden = true
            return
        }
        compositionLabel.attributedText = NSAttributedString(string: composition, attributes: [
            .font: UIFont.systemFont(ofSize: 17, weight: .medium),
            .foregroundColor: UIColor.white,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ])
        compositionLabel.isHidden = false
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard !compositionLabel.isHidden else { return }
        let size = compositionLabel.sizeThatFits(bounds.size)
        let width = min(size.width + 24, bounds.width - 16)
        compositionLabel.frame = CGRect(x: (bounds.width - width) / 2, y: bounds.height - 40, width: width, height: 32)
    }

    // MARK: - UITextInput：文档是听写那一段加上正在组的字

    private var documentLength: Int { tail.length + (composition?.utf16.count ?? 0) }

    /// 选区只落在组字里（光标前面那一段已经在 Mac 上了，挪不动）。
    var selectedTextRange: UITextRange? {
        get { RemoteTextRange(tail.length + selection.location, tail.length + selection.location + selection.length) }
        set {
            guard let range = newValue as? RemoteTextRange else { return }
            let length = composition?.utf16.count ?? 0
            let start = min(max(range.lower - tail.length, 0), length)
            selection = NSRange(location: start, length: min(max(range.upper - tail.length, start), length) - start)
        }
    }

    weak var inputDelegate: UITextInputDelegate?
    lazy var tokenizer: UITextInputTokenizer = UITextInputStringTokenizer(textInput: self)
    var beginningOfDocument: UITextPosition { RemoteTextPosition(0) }
    var endOfDocument: UITextPosition { RemoteTextPosition(documentLength) }

    func text(in range: UITextRange) -> String? {
        guard let range = range as? RemoteTextRange else { return "" }
        let units = Array((tail.text + (composition ?? "")).utf16)
        let lower = min(max(range.lower, 0), units.count), upper = min(range.upper, units.count)
        return String(decoding: units[lower..<max(lower, upper)], as: UTF16.self)
    }

    /// 没在组字时按范围改：听写改写那一段已上屏的字，先退格删掉新旧不同的部分，再补发新字。
    /// 原来忽略范围直接插入，就算听写没停也会把上一版再打一遍。
    func replace(_ range: UITextRange, withText text: String) {
        guard composition == nil, let range = range as? RemoteTextRange else {
            insertText(text)
            return
        }
        let lower = min(max(range.lower, 0), tail.length)
        let upper = min(max(range.upper, lower), tail.length)
        let edit = tail.replace(NSRange(location: lower, length: upper - lower), with: text)
        let asKeys = sendsKeyPresses
        applyTailEdit {
            for _ in 0..<edit.deletions { tap(RemoteKeyMap.Key.delete, modifiers: []) }
            deliver(edit.typed, armed: [], asKeys: asKeys)
        }
        if edit.typed.contains(where: \.isNewline) { tail.clear() }
    }

    func textRange(from fromPosition: UITextPosition, to toPosition: UITextPosition) -> UITextRange? {
        guard let from = fromPosition as? RemoteTextPosition, let to = toPosition as? RemoteTextPosition else { return nil }
        return RemoteTextRange(min(from.offset, to.offset), max(from.offset, to.offset))
    }

    func position(from position: UITextPosition, offset: Int) -> UITextPosition? {
        guard let position = position as? RemoteTextPosition else { return nil }
        let target = position.offset + offset
        return (0...documentLength).contains(target) ? RemoteTextPosition(target) : nil
    }

    func position(from position: UITextPosition, in direction: UITextLayoutDirection, offset: Int) -> UITextPosition? {
        switch direction {
        case .right, .down: return self.position(from: position, offset: offset)
        case .left, .up: return self.position(from: position, offset: -offset)
        @unknown default: return nil
        }
    }

    func compare(_ position: UITextPosition, to other: UITextPosition) -> ComparisonResult {
        let lhs = (position as? RemoteTextPosition)?.offset ?? 0, rhs = (other as? RemoteTextPosition)?.offset ?? 0
        return lhs == rhs ? .orderedSame : (lhs < rhs ? .orderedAscending : .orderedDescending)
    }

    func offset(from: UITextPosition, to toPosition: UITextPosition) -> Int {
        ((toPosition as? RemoteTextPosition)?.offset ?? 0) - ((from as? RemoteTextPosition)?.offset ?? 0)
    }

    func position(within range: UITextRange, farthestIn direction: UITextLayoutDirection) -> UITextPosition? {
        switch direction {
        case .left, .up: return range.start
        case .right, .down: return range.end
        @unknown default: return nil
        }
    }

    func characterRange(byExtending position: UITextPosition, in direction: UITextLayoutDirection) -> UITextRange? {
        guard let offset = (position as? RemoteTextPosition)?.offset else { return nil }
        switch direction {
        case .left, .up: return RemoteTextRange(0, offset)
        case .right, .down: return RemoteTextRange(offset, documentLength)
        @unknown default: return nil
        }
    }

    func baseWritingDirection(for position: UITextPosition, in direction: UITextStorageDirection)
        -> NSWritingDirection { .natural }

    func setBaseWritingDirection(_ writingDirection: NSWritingDirection, for range: UITextRange) {}

    /// 候选框贴着显示组字的那条。
    private var anchorRect: CGRect {
        CGRect(x: bounds.midX, y: max(0, bounds.height - 40), width: 1, height: 32)
    }

    func firstRect(for range: UITextRange) -> CGRect { anchorRect }
    func caretRect(for position: UITextPosition) -> CGRect { anchorRect }
    func selectionRects(for range: UITextRange) -> [UITextSelectionRect] { [] }
    func closestPosition(to point: CGPoint) -> UITextPosition? { endOfDocument }
    func closestPosition(to point: CGPoint, within range: UITextRange) -> UITextPosition? { range.end }
    func characterRange(at point: CGPoint) -> UITextRange? { nil }

    // MARK: - 键盘触控板（长按空格键滑动）

    /// 长按空格键时系统把手指的位置报给这三个方法。我们这边的文档是空的（字都在 Mac 上），
    /// 不接它们的话键盘照样变灰进入触控板，但手指怎么滑都没有反应。换算见 `RemoteKeyboardTrackpad`。
    func beginFloatingCursor(at point: CGPoint) {
        floatingSentArrows = false
        guard composition == nil else {
            floating = nil
            return
        }
        let mode = movePointer == nil ? .caret : trackpadMode
        floating = (RemoteKeyboardTrackpad(at: point, time: CACurrentMediaTime()), mode)
    }

    func updateFloatingCursor(at point: CGPoint) {
        guard var current = floating else { return }
        switch current.mode {
        case .caret:
            let codes = current.trackpad.arrows(to: point)
            // 键盘条上膛的修饰键作用于整次拖动：⇧ 是边拖边选，⌥ 是按词走，⌘ 是到行首行尾。松手时才熄灭。
            let modifiers = keys?.modifiers ?? []
            for code in codes { tap(code, modifiers: modifiers) }
            if !codes.isEmpty { floatingSentArrows = true }
        case .pointer:
            let move = current.trackpad.pointerMove(to: point, time: CACurrentMediaTime())
            if move.delta != .zero { movePointer?(move.delta, move.speed) }
        }
        floating = current
    }

    func endFloatingCursor() {
        if floatingSentArrows { _ = keys?.consume() }
        floating = nil
        floatingSentArrows = false
    }

    // MARK: - 外接键盘

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let armed = !(keys?.modifiers.isEmpty ?? true)
        let forSystem = presses.filter { press in
            guard let key = press.key else { return false }
            return RemoteKeyboardRouting.leavesToSystem(hidUsage: key.keyCode.rawValue, flags: key.modifierFlags, armed: armed,
                                                        composing: composition != nil, asKeys: sendsKeyPresses)
        }
        keysLeftToSystem.formUnion(forSystem.compactMap { $0.key?.keyCode.rawValue })
        if !forSystem.isEmpty { super.pressesBegan(forSystem, with: event) }
        let own = presses.subtracting(forSystem)
        if !own.isEmpty, !handle(own, down: true) { super.pressesBegan(own, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let forSystem = takeKeysLeftToSystem(from: presses)
        if !forSystem.isEmpty { super.pressesEnded(forSystem, with: event) }
        let own = presses.subtracting(forSystem)
        if !own.isEmpty, !handle(own, down: false) { super.pressesEnded(own, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        _ = takeKeysLeftToSystem(from: presses)
        super.pressesCancelled(presses, with: event)
    }

    private func takeKeysLeftToSystem(from presses: Set<UIPress>) -> Set<UIPress> {
        let matching = presses.filter { $0.key.map { keysLeftToSystem.contains($0.keyCode.rawValue) } ?? false }
        keysLeftToSystem.subtract(matching.compactMap { $0.key?.keyCode.rawValue })
        return matching
    }

    /// 外接键盘：HID 键位 → Mac 键码，修饰取按键自带的状态并上键盘条上膛的。返回 false = 不认识，交还系统。
    func handle(_ presses: Set<UIPress>, down: Bool) -> Bool {
        var handled = false
        for press in presses {
            guard let key = press.key else { continue }
            // 修饰键本身不单独发：修饰状态随每个按键一起带过去。
            if (0xE0...0xE7).contains(key.keyCode.rawValue) {
                handled = true
                continue
            }
            guard let code = RemoteKeyMap.keyCode(hidUsage: key.keyCode.rawValue) else { continue }
            if down { resetTail() }
            var modifiers = Self.modifiers(key.modifierFlags)
            if down { modifiers.formUnion(keys?.consume() ?? []) }
            send?(.key(code: code, down: down, modifiers: modifiers))
            handled = true
        }
        return handled
    }

    static func modifiers(_ flags: UIKeyModifierFlags) -> RemoteKeyModifiers {
        var result: RemoteKeyModifiers = []
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.alternate) { result.insert(.option) }
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.alphaShift) { result.insert(.capsLock) }
        return result
    }
}

private final class RemoteTextPosition: UITextPosition {
    let offset: Int
    init(_ offset: Int) { self.offset = offset }
}

private final class RemoteTextRange: UITextRange {
    let lower: Int
    let upper: Int
    init(_ lower: Int, _ upper: Int) {
        self.lower = lower
        self.upper = upper
    }
    override var start: UITextPosition { RemoteTextPosition(lower) }
    override var end: UITextPosition { RemoteTextPosition(upper) }
    override var isEmpty: Bool { lower == upper }
}
