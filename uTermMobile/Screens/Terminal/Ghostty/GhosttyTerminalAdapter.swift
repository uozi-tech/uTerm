import Foundation
import GhosttyKit
import GhosttyTerminal
import SwiftTerm
import UIKit

// SPIKE：iOS 侧接 GhosttyKit（libghostty-spm 2.2.2026110702）的最小适配层，评估用，App 里没有任何入口。
// 结论与读数见 docs/ghostty-eval/ios-spike.md。这里只做三件事：
// 1. `MGhosttyTerminalView`：UITerminalView 子类，落 uTerm 的本地输入策略（补丁 #2 / #8 的 uTerm 侧）；
// 2. `GhosttyTerminalBridge`：host-managed IO —— 后端字节 → `InMemoryTerminalSession.receive`，
//    用户输入 / 网格尺寸 → 共享的 `TerminalInputChannel`（同一条 FIFO，和 SwiftTerm 路径一样）；
// 3. `TerminalKeyBar` 的键怎么落到 GhosttyKit 的按键 API（`GhosttyKeyBarMapping`）。
//
// 命名：GhosttyTerminal 也导出了 `TerminalKey` / `TerminalColorScheme` / `TerminalController` / `TerminalTheme`，
// 本模块里同名的 uTerm 类型优先，所以 GhosttyKit 的一律写全 `GhosttyTerminal.`。

/// uTerm 的终端视图策略，全部是子类覆写，不改上游。
final class MGhosttyTerminalView: UITerminalView {
    /// 和 `MTerminalView.canBecomeFirstResponder` 同一条规则：只有轮到自己的会话才肯拿键盘。nil = 不拦（探针用）。
    var canTakeKeyboard: (() -> Bool)?

    override var canBecomeFirstResponder: Bool { canTakeKeyboard?() ?? true }

    // MARK: 补丁 #2：键盘类型可写（上游 getter 恒为 .default、setter 是空实现）

    /// `.asciiCapable` 强制 ASCII 键盘；uTerm 现在用 `.default` + 下面的 `textInputMode` 做「默认英文」。
    var preferredKeyboardType: UIKeyboardType = .default {
        didSet { if isFirstResponder { reloadInputViews() } }
    }

    override var keyboardType: UIKeyboardType {
        get { preferredKeyboardType }
        set { preferredKeyboardType = newValue }
    }

    // MARK: 补丁 #8 的 uTerm 侧：键盘默认英文，用户切了就记住（与 MTerminalView 同一套）

    private var chosenInputMode: UITextInputMode?
    private var observesInputMode = false

    override var textInputMode: UITextInputMode? {
        chosenInputMode ?? Self.englishInputMode ?? super.textInputMode
    }

    private static var englishInputMode: UITextInputMode? {
        UITextInputMode.activeInputModes.first { $0.primaryLanguage?.hasPrefix("en") == true }
    }

    @discardableResult
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
        guard isFirstResponder, let mode = super.textInputMode else { return }
        chosenInputMode = mode
    }

    // MARK: 补丁 #8 的另一半：候选框锚点（GhosttyKit 2.2.2026110702 低了一行）

    /// GhosttyKit 把 `ghostty_surface_ime_point` 的 y 当成格子顶边，可它是格子底边（Ghostty 的 macOS 前端按
    /// 「左下角」用它）。实测组字画在 y=76、锚点报 y=90.67，正好差一行（行高 14.67）。上移一个自身高度对齐。
    /// 宽度也偏大（按像素没除屏幕倍率），候选框只用到原点和高度，这里不动。上游修了就删掉这两个覆写。
    override func firstRect(for range: UITextRange) -> CGRect {
        Self.liftedOneRow(super.firstRect(for: range))
    }

    override func caretRect(for position: UITextPosition) -> CGRect {
        Self.liftedOneRow(super.caretRect(for: position))
    }

    nonisolated static func liftedOneRow(_ rect: CGRect) -> CGRect {
        guard !rect.isNull, rect.height > 0 else { return rect }
        return rect.offsetBy(dx: 0, dy: -rect.height)
    }
}

/// 一条 GhosttyKit 终端：视图 + host-managed 会话 + uTerm 的输入通道。
///
/// 字节流方向：
/// - 远端 → 终端：`feed(_:)` / `bind(_:)` 直接 `session.receive`。GhosttyKit 在自己的串行队列上解析，
///   按 vsync 在主线程画（`TerminalSurfaceCoordinator` 的 display link），所以**不需要** `TerminalOutputPump`
///   与 `TerminalFlushPacing`：那两样是为了不让 SwiftTerm 在主线程上解析、画太多帧。
/// - 终端 → 远端：键盘 / 粘贴 / 查询应答从 `InMemoryTerminalSession` 的 write 回调出来（可能在任意线程），
///   跳回主线程进 `TerminalInputChannel`；网格尺寸走 resize 回调进同一个通道（同轮合并、相同不重发）。
@MainActor
final class GhosttyTerminalBridge {
    let view: MGhosttyTerminalView
    let session: InMemoryTerminalSession
    let input = TerminalInputChannel()
    /// 最近一次 resize 回调报来的网格（探针读它）。
    private(set) var grid: (cols: Int, rows: Int)?
    /// resize 回调次数（探针读它，看转屏时远端会收到几次 SIGWINCH）。
    private(set) var resizeReports = 0
    /// 每一块 write 回调给出的字节（探针读它，核按键编码）。nil = 不记。
    var inputLog: [Data]?
    private var ingress: Task<Void, Never>?

    /// Ghostty 的 `font-size` 在 iOS 上按 96 dpi 换算（实测 11 → 格子 8.93×19.49pt，SwiftTerm 11pt SF Mono 是 6.78×14.07pt，
    /// 宽高都差 ≈4/3）。要和 SwiftTerm 的 11pt 一样大，传 11 × 72/96。
    nonisolated static func ghosttyFontSize(points: CGFloat) -> Float {
        Float(points * 72 / 96)
    }

    /// 整个 App 共用一个 ghostty app（`TerminalController`）。配置在这里定：字号、光标、配色、最低对比度。
    static func makeController(dark: Bool, fontSize: Float) -> GhosttyTerminal.TerminalController {
        let scheme = TerminalColorScheme.resolve(dark: dark)
        return GhosttyTerminal.TerminalController { builder in
            builder.withFontSize(fontSize)
            builder.withCursorStyleBlink(TerminalCursorPreference.defaultBlink)
            builder.withBackgroundOpacity(1)
            builder.withBackground(Self.hex(scheme.backgroundColor))
            builder.withForeground(Self.hex(scheme.foregroundColor))
            for (index, color) in scheme.ansiColors.prefix(16).enumerated() {
                builder.withPalette(index, color: Self.hex(color))
            }
            // 补丁 #1 的原生对应物：Ghostty 自带 minimum-contrast（同为 WCAG 比值）。
            builder.withMinimumContrast(Double(TerminalColorScheme.minimumContrastRatio))
        }
    }

    init(controller: GhosttyTerminal.TerminalController, frame: CGRect = .zero) {
        let box = WeakBridgeBox()
        session = InMemoryTerminalSession(
            write: { data in
                Task { @MainActor in box.bridge?.userInput(data) }
            },
            resize: { viewport in
                Task { @MainActor in box.bridge?.gridChanged(cols: Int(viewport.columns), rows: Int(viewport.rows)) }
            },
            // uTerm 只消费行列数；像素级的尺寸变化（拖分隔条时绝大多数）不必让远端重绘。
            suppressesPixelOnlyResizes: true)
        view = MGhosttyTerminalView(frame: frame)
        view.controller = controller
        view.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
        // 去掉 GhosttyKit 自带的按键辅助条：uTerm 用自己的 `TerminalKeyBar`（同 SwiftTerm 路径置 nil）。
        view.inputAccessoryItems = []
        box.bridge = self
    }

    /// 喂远端输出。线程安全、不阻塞；解析在 GhosttyKit 的串行队列上。
    nonisolated func feed(_ data: Data) {
        session.receive(data)
    }

    /// 接到一个后端：输出直接进会话，输入 / 尺寸走共享通道。
    func bind(_ backend: any TerminalBackend) {
        input.bind(to: backend, sendingLatestSize: true)
        ingress?.cancel()
        let session = session
        let output = backend.outputStream
        ingress = Task.detached(priority: .userInitiated) {
            for await chunk in output {
                if Task.isCancelled { break }
                session.receive(chunk)
            }
        }
    }

    func unbind() {
        ingress?.cancel()
        ingress = nil
        input.unbind()
    }

    private func userInput(_ data: Data) {
        inputLog?.append(data)
        input.write(data)
    }

    private func gridChanged(cols: Int, rows: Int) {
        resizeReports += 1
        grid = (cols, rows)
        input.reportSize(cols: UInt16(clamping: cols), rows: UInt16(clamping: rows))
    }

    // MARK: 键盘条

    /// 键盘条上的一个键。能对上 GhosttyKit 按键的走按键路径（由终端按当前模式编码：DECCKM 下方向键发
    /// `ESC O A`、kitty 键盘协议下发 CSI u），对不上的（符号、提示词）走文字路径。
    func send(_ key: uTermMobile.TerminalKey) {
        if let press = GhosttyKeyBarMapping.press(for: key) {
            view.sendKey(press)
        } else if key.send.count == 1, let char = key.send.first, let press = TerminalKeyPress(typing: char) {
            // 单个符号按「打字」发：不会被括号粘贴包起来（Claude Code 会把粘贴的 "/" 当成粘贴内容）。
            view.sendKey(press)
        } else {
            session.sendInput(Data(key.send.utf8))
        }
    }

    /// 粘滞 Ctrl / Alt：GhosttyKit 原生（作用于下一个软键盘字符或按键，用完自动复位；连点两下锁定）。
    func toggleSticky(_ modifier: TerminalPublicStickyModifier) {
        view.toggleStickyModifier(modifier)
    }

    private static func hex(_ color: UIColor) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X", Int(r * 255 + 0.5), Int(g * 255 + 0.5), Int(b * 255 + 0.5))
    }

    private static func hex(_ color: SwiftTerm.Color) -> String {
        String(format: "#%02X%02X%02X", Int(color.red >> 8), Int(color.green >> 8), Int(color.blue >> 8))
    }
}

/// write / resize 回调是 `@Sendable` 的、可能在任意线程上来，只带一个弱引用回主线程（类本身是 MainActor 的，所以可跨线程传）。
private final class WeakBridgeBox {
    weak var bridge: GhosttyTerminalBridge?
}

/// `TerminalKeyCatalog` → GhosttyKit 按键。只映射「按键」，符号与提示词照旧当文字发。
enum GhosttyKeyBarMapping {
    static func press(for key: uTermMobile.TerminalKey) -> TerminalKeyPress? {
        switch key.send {
        case "\u{1b}": return TerminalKeyPress(.escape)
        case "\t": return TerminalKeyPress(.tab)
        case "\u{1b}[Z": return TerminalKeyPress(.tab, modifiers: .shift)
        case "\r": return TerminalKeyPress(.enter)
        case "\u{7f}": return TerminalKeyPress(.backspace)
        case "\u{1b}[A": return TerminalKeyPress(.arrowUp)
        case "\u{1b}[B": return TerminalKeyPress(.arrowDown)
        case "\u{1b}[C": return TerminalKeyPress(.arrowRight)
        case "\u{1b}[D": return TerminalKeyPress(.arrowLeft)
        case "\u{1b}[H": return TerminalKeyPress(.home)
        case "\u{1b}[F": return TerminalKeyPress(.end)
        case "\u{1b}[5~": return TerminalKeyPress(.pageUp)
        case "\u{1b}[6~": return TerminalKeyPress(.pageDown)
        case "\u{1b}[3~": return TerminalKeyPress(.delete)
        case "\u{1b}[2~": return TerminalKeyPress(.insert)
        default: break
        }
        if let index = TerminalKeyCatalog.function.firstIndex(of: key) {
            let keys: [GhosttyTerminal.TerminalKey] = [.f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12]
            return TerminalKeyPress(keys[index])
        }
        // ^A … ^Z：Ctrl + 字母。
        if let scalar = key.send.unicodeScalars.first, key.send.unicodeScalars.count == 1,
           (1...26).contains(scalar.value),
           let letter = Character(UnicodeScalar(scalar.value + 0x60)!).lowercased().first,
           let press = TerminalKeyPress(typing: letter, modifiers: .ctrl) {
            return press
        }
        return nil
    }
}
