#if os(macOS)
import AppKit
import SwiftUI
import UDesignKit

/// 定长数字码输入（Mac）：`length` 个格子各显示一位，三位一组（和显示端的「123 456」对上）。
///
/// 按验证码输入的通行做法：
/// - 整个控件是一个输入焦点，不逐格切：打字接在后面，退格删最后一位，⌘V 粘贴整串（带空格、横线也行）；
/// - 只收数字，全角数字换成半角；
/// - 输满即回调 `onComplete`，不用再点按钮；回车在输满时也回调；
/// - 当前位描强调色边并画一道光标（不闪：常驻动画会让整窗每帧重画）；`isError` 时描红，`shakes` 每加一就左右晃一下；
/// - 读屏当成一个文本框，值一位一位念。
///
/// 收键的是一个盖在格子上的 `NSView`（`UCodeKeyCatcher`），不是藏起来的 `NSTextField`：文本框一拿到焦点就全选，
/// 接着打的第一位会把已经输的冲掉；浮动面板（`.nonactivatingPanel`）成为 key 窗口而 App 不在前台时，⌘V 也到不了
/// 「编辑 › 粘贴」那条菜单，要自己在 `performKeyEquivalent` 里接。
struct UCodeField: View {
    @Binding var code: String
    var length: Int = 6
    var groupSize: Int = 3
    var isError: Bool = false
    /// 每加一晃一下（码不对时）。
    var shakes: Int = 0
    var onComplete: (String) -> Void = { _ in }

    @State private var focused = false

    static let cellSize = CGSize(width: 40, height: 48)
    static let cellSpacing: CGFloat = 8
    static let groupSpacing: CGFloat = 18

    var body: some View {
        HStack(spacing: 0) {
            ForEach(0..<length, id: \.self) { index in
                cell(index)
                    .padding(.leading, leading(before: index))
            }
        }
        .modifier(UCodeShake(animatableData: CGFloat(shakes)))
        .animation(.linear(duration: 0.36), value: shakes)
        .overlay {
            UCodeKeyCatcher(code: $code, length: length, focused: $focused,
                            onSubmit: { if code.count == length { onComplete(code) } })
        }
        .frame(maxWidth: .infinity)
        .onChange(of: code) { _, value in
            let normalized = CodeFieldInput.normalize(value, length: length)
            if normalized != value { code = normalized; return }
            if normalized.count == length { onComplete(normalized) }
        }
    }

    private func leading(before index: Int) -> CGFloat {
        guard index > 0 else { return 0 }
        return groupSize > 0 && index % groupSize == 0 ? Self.groupSpacing : Self.cellSpacing
    }

    private func cell(_ index: Int) -> some View {
        let digits = Array(code)
        let digit = index < digits.count ? String(digits[index]) : ""
        // 当前位 = 下一个要输入的位；输满后是最后一位。
        let isCurrent = focused && index == min(digits.count, length - 1)
        let border: Color = isError ? UD.danger : (isCurrent ? UD.accent : .clear)
        let ring: Color = isError ? UD.danger.opacity(0.12) : (isCurrent ? UD.accent.opacity(0.13) : .clear)
        return ZStack {
            Text(digit)
                .font(UD.mono(22, weight: .semibold))
                .foregroundStyle(UD.text)
            if isCurrent, digit.isEmpty {
                RoundedRectangle(cornerRadius: 1)
                    .fill(UD.accent)
                    .frame(width: 2, height: 22)
            }
        }
        .frame(width: Self.cellSize.width, height: Self.cellSize.height)
        .background(RoundedRectangle(cornerRadius: UD.Radius.md).fill(UD.inputBg))
        .overlay(RoundedRectangle(cornerRadius: UD.Radius.md).strokeBorder(border, lineWidth: 1))
        .overlay(RoundedRectangle(cornerRadius: UD.Radius.md).stroke(ring, lineWidth: 3))
        .animation(.easeOut(duration: 0.12), value: isCurrent)
    }
}

/// 左右晃：`animatableData` 每加一晃三个来回。
private struct UCodeShake: GeometryEffect {
    var animatableData: CGFloat

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 6 * sin(animatableData * .pi * 6), y: 0))
    }
}

/// 盖在格子上收键、收点击的视图。
private struct UCodeKeyCatcher: NSViewRepresentable {
    @Binding var code: String
    let length: Int
    @Binding var focused: Bool
    let onSubmit: () -> Void

    func makeNSView(context: Context) -> UCodeKeyView {
        let view = UCodeKeyView()
        update(view)
        return view
    }

    func updateNSView(_ view: UCodeKeyView, context: Context) {
        update(view)
    }

    private func update(_ view: UCodeKeyView) {
        view.length = length
        view.code = code
        view.onChange = { code = $0 }
        view.onFocus = { value in
            if focused != value { focused = value }
        }
        view.onSubmit = onSubmit
        view.setAccessibilityValue(CodeFieldInput.spoken(code))
    }
}

final class UCodeKeyView: NSView {
    var length = 6
    var code = ""
    var onChange: (String) -> Void = { _ in }
    var onFocus: (Bool) -> Void = { _ in }
    var onSubmit: () -> Void = {}
    /// ⌘V 读的剪贴板（测试里换成自己的一块，不碰系统那块）。
    var pasteboard: NSPasteboard = .general

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.textField)
        setAccessibilityLabel(String(localized: "数字码"))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let center = NotificationCenter.default
        center.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
        center.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        guard let window else { return }
        center.addObserver(self, selector: #selector(windowKeyChanged), name: NSWindow.didBecomeKeyNotification, object: window)
        center.addObserver(self, selector: #selector(windowKeyChanged), name: NSWindow.didResignKeyNotification, object: window)
        // 一出现就把焦点放在这里：窗口成为 key（点一下面板）之后直接打字。不抢 key 窗口。
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window, window.firstResponder !== self else { return }
            window.makeFirstResponder(self)
        }
    }

    @objc private func windowKeyChanged() {
        reportFocus()
    }

    override func becomeFirstResponder() -> Bool {
        defer { reportFocus(isFirstResponder: true) }
        return true
    }

    override func resignFirstResponder() -> Bool {
        defer { reportFocus(isFirstResponder: false) }
        return true
    }

    private func reportFocus(isFirstResponder: Bool? = nil) {
        let first = isFirstResponder ?? (window?.firstResponder === self)
        onFocus(first && window?.isKeyWindow == true)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        interpretKeyEvents([event])
    }

    override func insertText(_ insertString: Any) {
        let text = (insertString as? String) ?? (insertString as? NSAttributedString)?.string ?? ""
        set(CodeFieldInput.appending(text, to: code, length: length))
    }

    override func deleteBackward(_ sender: Any?) {
        set(CodeFieldInput.deletingLast(from: code))
    }

    override func deleteToBeginningOfLine(_ sender: Any?) {
        set("")
    }

    override func insertNewline(_ sender: Any?) {
        onSubmit()
    }

    /// 别的编辑命令（方向键、Esc……）不处理也不响铃；Tab 照常走焦点链。
    override func doCommand(by selector: Selector) {
        switch selector {
        case #selector(deleteBackward(_:)): deleteBackward(nil)
        case #selector(deleteToBeginningOfLine(_:)): deleteToBeginningOfLine(nil)
        case #selector(insertNewline(_:)): insertNewline(nil)
        case #selector(insertTab(_:)): window?.selectNextKeyView(self)
        case #selector(insertBacktab(_:)): window?.selectPreviousKeyView(self)
        default: break
        }
    }

    /// ⌘V：面板是 key 窗口而 App 不在前台时菜单接不到，这里直接接。
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
              event.charactersIgnoringModifiers?.lowercased() == "v" else {
            return super.performKeyEquivalent(with: event)
        }
        paste(nil)
        return true
    }

    @objc func paste(_ sender: Any?) {
        guard let text = pasteboard.string(forType: .string) else { return }
        set(CodeFieldInput.pasting(text, over: code, length: length))
    }

    private func set(_ value: String) {
        guard value != code else { return }
        code = value
        onChange(value)
    }
}
#endif
