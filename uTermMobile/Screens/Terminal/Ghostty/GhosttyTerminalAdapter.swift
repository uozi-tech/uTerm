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
// 后来加的（M10，iOS 后台）：每条终端带一个影子终端（`ShadowTerminal`，libghostty-vt），输出经 `GhosttyOutputRouter`
// 分流——App 在后台时只喂影子，回前台把影子的快照回放进 surface。原因与读数见 docs/ghostty-eval/measure-ios.md 的 M10。
//
// 命名：GhosttyTerminal 也导出了 `TerminalKey` / `TerminalColorScheme` / `TerminalController` / `TerminalTheme`，
// 本模块里同名的 uTerm 类型优先，所以 GhosttyKit 的一律写全 `GhosttyTerminal.`。

/// uTerm 的终端视图策略，全部是子类覆写，不改上游。
final class MGhosttyTerminalView: UITerminalView {
    /// 和 `MTerminalView.canBecomeFirstResponder` 同一条规则：只有轮到自己的会话才肯拿键盘。nil = 不拦（探针用）。
    var canTakeKeyboard: (() -> Bool)?

    override var canBecomeFirstResponder: Bool { canTakeKeyboard?() ?? true }
    /// 第一响应者变化（宿主据此同步「键盘在不在这个会话上」）。
    var onFocusChanged: ((Bool) -> Void)?

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
/// - 远端 → 终端：`feed(_:)` / `bind(_:)` 经 `router` 分流：先进影子终端（同步解析），App 在前台时再 `session.receive`。
///   GhosttyKit 在自己的串行队列上解析，按 vsync 在主线程画（`TerminalSurfaceCoordinator` 的 display link），所以**不需要**
///   `TerminalOutputPump` 与 `TerminalFlushPacing`：那两样是为了不让 SwiftTerm 在主线程上解析、画太多帧。
///   App 在后台时 surface 不吃字节（GhosttyKit 后台不 tick，标题这类消息会把解析卡死），回前台由影子的快照回放补齐。
/// - 终端 → 远端：键盘 / 粘贴 / 查询应答从 `InMemoryTerminalSession` 的 write 回调出来（可能在任意线程），
///   跳回主线程进 `TerminalInputChannel`；网格尺寸走 resize 回调进同一个通道（同轮合并、相同不重发）。
@MainActor
final class GhosttyTerminalBridge {
    let view: MGhosttyTerminalView
    let session: InMemoryTerminalSession
    /// 影子终端：和 surface 吃同一份字节，后台时只有它在吃。读状态、拍快照都找它。
    let shadow: ShadowTerminal
    /// 输出分流（影子永远收、surface 只在前台收）与入站的闸门。
    let router: GhosttyOutputRouter
    let input = TerminalInputChannel()
    /// 最近一次 resize 回调报来的网格（探针读它）。
    private(set) var grid: (cols: Int, rows: Int)?
    /// 最近一次 resize 回调报来的格子像素尺寸（探针读它，核字体）。
    private(set) var cellPixels: (width: UInt32, height: UInt32)?
    /// resize 回调次数（探针读它，看转屏时远端会收到几次 SIGWINCH）。
    private(set) var resizeReports = 0
    /// 每一块 write 回调给出的字节（探针读它，核按键编码）。nil = 不记。
    var inputLog: [Data]?
    private var ingress: Task<Void, Never>?
    /// App 在不在后台（`didEnterBackground` → `willEnterForeground`，和 `MobileTerminalController` 同一对通知）。
    private(set) var isAppInBackground = false
    // nonisolated(unsafe)：只在主线程设，deinit 里读。
    private nonisolated(unsafe) var lifecycleObservers: [NSObjectProtocol] = []

    /// 回滚上限，surface 与影子显式设成同一个值（M4 的前提：只设行数时 vt 的默认字节上限会把 1 万行裁到约 1 千行；
    /// 两边不一样的话回放进 surface 的历史长度和它自己攒的不同）。字节按「行数 × 1 KB」给（计划第 4 步的算法）。
    /// 另一个作用是给回前台的回放封顶：1 万行回滚拍快照 + 出回放流 + 自查，Duo 上热着跑约 3 ms，回前台那一下（冷）约 15 ms。
    nonisolated static let scrollbackLines = 10_000
    nonisolated static let scrollbackBytes = scrollbackLines * 1000

    /// Ghostty 的 `font-size` 在 iOS 上按 96 dpi 换算（实测 11 → 格子 8.93×19.49pt，SwiftTerm 11pt SF Mono 是 6.78×14.07pt，
    /// 宽高都差 ≈4/3）。要和 SwiftTerm 的 11pt 一样大，传 11 × 72/96。
    nonisolated static func ghosttyFontSize(points: CGFloat) -> Float {
        Float(points * 72 / 96)
    }

    /// 整个 App 共用一个 ghostty app（`TerminalController`）。配置在这里定：字体、字号、光标、留白、最低对比度；
    /// 配色作为 `theme` 传（深 / 浅两份都来自 uTerm 的 `TerminalColorScheme`），GhosttyKit 按视图的日夜自己切。
    ///
    /// 配色必须走 `theme`：controller 先装 base config、再把 theme 叠上去；不传 theme 时用的是 GhosttyKit 自带的
    /// Alabaster / Afterglow，会把 base 里的 background / foreground / palette / cursor-color 全部盖掉
    ///（M16 实机：浅色底成了 #F7F7F7、深色 #212121、光标蓝块，和外面 uTerm 的终端底色对不上，左右露出两条）。
    static func makeController(fontSize: Float) -> GhosttyTerminal.TerminalController {
        let theme = GhosttyTerminal.TerminalTheme(light: colors(TerminalColorScheme.resolve(dark: false)),
                                                  dark: colors(TerminalColorScheme.resolve(dark: true)))
        return GhosttyTerminal.TerminalController(theme: theme) { builder in
            // 和 SwiftTerm 同一个字体：iOS 的 SF Mono 只认这个私有 family 名（M12 实测；"SF Mono" 等名字都回退）。
            builder.withFontFamily(UIFont.monospacedSystemFont(ofSize: 11, weight: .regular).familyName)
            builder.withFontSize(fontSize)
            builder.withCursorStyleBlink(TerminalCursorPreference.defaultBlink)
            builder.withBackgroundOpacity(1)
            // SwiftTerm 没有内留白：网格从左上角排起，余下的不到一格留在右 / 下边，由外层 8pt 边距同色铺底。
            builder.withWindowPaddingX(0)
            builder.withWindowPaddingY(0)
            builder.withCustom("window-padding-color", "extend")
            // 补丁 #1 的原生对应物：minimum-contrast（同为 WCAG 比值）。上游 Ghostty 判不过就直接换成黑 / 白；
            // 我们的 GhosttyKit（补丁 0022）改成和 SwiftTerm 一样保色相、只调明度。
            builder.withMinimumContrast(Double(TerminalColorScheme.minimumContrastRatio))
            // 以下三项对齐 SwiftTerm 的着色规则（M16 第二轮逐格对比查出来的）：
            // - 256 色的 16–255 由 16 色 + 底色 / 前景按 CIELAB 生成，和 SwiftTerm 默认的 `.base16Lab` 是同一个算法
            //  （同出 jake-stewart 的提案）；不开的话 Ghostty 用固定的 xterm 表，p10k 的 38;5;103 等全不一样，浅色下灰阶还是反的。
            builder.withCustom("palette-generate", "true")
            // - 粗体的 0–7 号色用亮色（SwiftTerm `useBrightColors`）。
            builder.withCustom("bold-color", "bright")
            // - dim 按 sRGB（伽马空间）和底色五五开混合，同 SwiftTerm / CoreGraphics；iOS 默认的 linear-corrected
            //   在线性空间混合，dim 字会亮一截。
            builder.withCustom("alpha-blending", "native")
            builder.withCustom("faint-opacity", "0.5")
            // 回滚上限：与影子终端同一个值（见 `scrollbackLines`）。不设的话是 Ghostty 的默认 50 MB、不限行数。
            builder.withCustom("scrollback-limit-lines", "\(scrollbackLines)")
            builder.withCustom("scrollback-limit-bytes", "\(scrollbackBytes)")
        }
    }

    /// 一份 uTerm 配色 → Ghostty 配置：底色、前景、16 色、光标（块光标下的字用终端底色，同 `TerminalAppearance.applyCaretColors`）、选区。
    private static func colors(_ scheme: TerminalColorScheme) -> GhosttyTerminal.TerminalConfiguration {
        GhosttyTerminal.TerminalConfiguration { builder in
            let background = hex(scheme.backgroundColor)
            builder.withBackground(background)
            builder.withForeground(hex(scheme.foregroundColor))
            for (index, color) in scheme.ansiColors.prefix(16).enumerated() {
                builder.withPalette(index, color: hex(color))
            }
            builder.withCursorColor(hex(scheme.cursorColor))
            builder.withCursorText(background)
            builder.withSelectionBackground(hex(scheme.selectionColor, over: scheme.backgroundColor))
            builder.withSelectionForeground(hex(scheme.foregroundColor))
        }
    }

    /// 影子终端的配置：和 `makeController` 给 surface 的配置对得上的那几项。
    private static func shadowOptions() -> ShadowTerminal.Options {
        var options = ShadowTerminal.Options(scrollbackLines: scrollbackLines, scrollbackBytes: scrollbackBytes)
        options.cursorBlink = TerminalCursorPreference.defaultBlink
        // 后台时影子替 surface 答 XTVERSION；surface 答的是「ghostty <版本>」。
        let info = ghostty_info()
        if let version = info.version, info.version_len > 0 {
            let bytes = UnsafeBufferPointer(start: UnsafeRawPointer(version).assumingMemoryBound(to: UInt8.self),
                                            count: Int(info.version_len))
            options.versionReport = "ghostty " + String(decoding: bytes, as: UTF8.self)
        }
        return options
    }

    init(controller: GhosttyTerminal.TerminalController, frame: CGRect = .zero) {
        let box = WeakBridgeBox()
        // 先按 80×24 建，surface 的终端报出真实网格后跟着改（见下面的 resize 回调）。
        let shadow = ShadowTerminal(cols: 80, rows: 24, options: Self.shadowOptions())
        let session = InMemoryTerminalSession(
            write: { data in
                Task { @MainActor in box.bridge?.userInput(data) }
            },
            resize: { viewport in
                // 影子跟着 surface 的终端自己报的尺寸走，而且就在这个回调里改、不绕主线程（M4 的前提：按视图尺寸算或者
                // 晚一拍改，两边会在不同的字节位置换宽度，折行就对不上了）。
                shadow.resize(cols: viewport.columns, rows: viewport.rows,
                              cellWidth: viewport.cellWidthPixels, cellHeight: viewport.cellHeightPixels)
                Task { @MainActor in
                    box.bridge?.cellPixels = (viewport.cellWidthPixels, viewport.cellHeightPixels)
                    box.bridge?.gridChanged(cols: Int(viewport.columns), rows: Int(viewport.rows))
                }
            },
            // uTerm 只消费行列数；像素级的尺寸变化（拖分隔条时绝大多数）不必让远端重绘。
            suppressesPixelOnlyResizes: true)
        self.session = session
        self.shadow = shadow
        router = GhosttyOutputRouter(session: session, shadow: shadow)
        view = MGhosttyTerminalView(frame: frame)
        view.controller = controller
        view.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
        // 去掉 GhosttyKit 自带的按键辅助条：uTerm 用自己的 `TerminalKeyBar`（同 SwiftTerm 路径置 nil）。
        view.inputAccessoryItems = []
        box.bridge = self
        // 后台时查询由影子答（DA、DSR、光标位置、颜色查询……），和 surface 的应答走同一条路回后端。
        shadow.setReplyHandler { data in
            Task { @MainActor in box.bridge?.userInput(data) }
        }
        installLifecycleObservers()
        if UIApplication.shared.applicationState == .background { setAppInBackground(true) }
    }

    deinit {
        lifecycleObservers.forEach(NotificationCenter.default.removeObserver)
    }

    /// 喂远端输出。线程安全；影子当场解析，surface 的解析在 GhosttyKit 的串行队列上。不过闸门（测试与探针直接喂用）。
    nonisolated func feed(_ data: Data) {
        router.route(data)
    }

    /// 接到一个后端：输出经分流进影子与 surface，输入 / 尺寸走共享通道。
    ///
    /// 背压：surface 没解析完的字节到 `GhosttyOutputRouter.highWater`（1 MiB）时入站任务不再取下一块，落回低水位再取。
    /// 取不动的字节留在后端的 `outputStream` 里——那条流（以及 Citadel 的 PTY 输出流）现在是不限长的，所以这还不是
    /// 真正压到 SSH 窗口上的背压，只保证终端这一层有上界；要压到远端得改 Citadel（见 measure-ios.md 的 M10）。
    func bind(_ backend: any TerminalBackend) {
        input.bind(to: backend, sendingLatestSize: true)
        ingress?.cancel()
        router.reopen()
        let router = router
        let output = backend.outputStream
        ingress = Task.detached(priority: .userInitiated) {
            for await chunk in output {
                if Task.isCancelled { break }
                await router.ingest(chunk)
            }
        }
    }

    func unbind() {
        ingress?.cancel()
        ingress = nil
        router.close()
        input.unbind()
    }

    // MARK: 进出后台（M10）

    /// 用 didEnterBackground / willEnterForeground，不用 resign / becomeActive：拉下控制中心、来电横幅时 App 只是
    /// inactive，GhosttyKit 照常 tick，不用切。只看 App 级的通知；iPad 多窗口里单个场景退后台没接（那时 GhosttyKit
    /// 也只停那个场景的视图，别的场景还在 tick，mailbox 有人清）。
    private func installLifecycleObservers() {
        let center = NotificationCenter.default
        lifecycleObservers = [
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setAppInBackground(true) }
            },
            center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setAppInBackground(false) }
            },
        ]
    }

    /// App 进出后台。进后台：从这一刻起输出只喂影子终端，surface 不再吃字节（GhosttyKit 后台不 tick，带标题的输出
    /// 约 64 帧就把 app mailbox 填满、解析卡死）；影子开始替 surface 应答查询。回前台：把影子的快照回放进 surface
    ///（后台队列上做），再接实时字节。重复调用无害。通知驱动；`MobileTerminalController` 也会转过来，测试直接调。
    func setAppInBackground(_ inBackground: Bool) {
        guard inBackground != isAppInBackground else { return }
        isAppInBackground = inBackground
        if inBackground {
            // 后台答颜色查询要用当前配色（OSC 10 / 11、`CSI ? 996 n`）。
            let dark = view.traitCollection.userInterfaceStyle != .light
            let scheme = TerminalColorScheme.resolve(dark: dark)
            shadow.setDefaultColors(foreground: Self.rgb(scheme.foregroundColor), background: Self.rgb(scheme.backgroundColor),
                                    cursor: Self.rgb(scheme.cursorColor), dark: dark)
        }
        router.setSurfaceFeeding(!inBackground)
    }

    private static func rgb(_ color: UIColor) -> (UInt8, UInt8, UInt8) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        func byte(_ value: CGFloat) -> UInt8 { UInt8(max(0, min(255, Int(value * 255 + 0.5)))) }
        return (byte(r), byte(g), byte(b))
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

    /// `over` 给了就按透明度合成到它上面（Ghostty 的颜色值不带 alpha）。
    private static func hex(_ color: UIColor, over base: UIColor? = nil) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        if let base, a < 1 {
            var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
            base.getRed(&br, green: &bg, blue: &bb, alpha: &ba)
            r = r * a + br * (1 - a); g = g * a + bg * (1 - a); b = b * a + bb * (1 - a)
        }
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
