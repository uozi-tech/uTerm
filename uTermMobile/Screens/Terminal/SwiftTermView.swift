import SwiftUI
import SwiftTerm
import UIKit

extension EnvironmentValues {
    /// 正在连续改宽度（拖分隔条）：字号先不跟，松手再换。字号随宽度连续变化，跟着换等于每帧重排一次。
    @Entry var mTerminalHoldsFontSize = false
}

/// 只在自己的会话允许时才肯当第一响应者的终端视图。
/// 光在我们自己的聚焦调用里设卡不够：UIKit 收起抽屉 / 弹层时会把之前的第一响应者自动恢复回来，
/// 不经过任何我们的代码——第一个标签已连上、第二个标签正在建连时，键盘就是这样冒出来的。
final class MTerminalView: SwiftTerm.TerminalView {
    weak var controller: MobileTerminalController?
    /// 是否已按真实窗格排布过。首次排布立即生效（此时还没有程序在画），之后的变化都要等停稳，
    /// 见 `MTerminalContainerView`。
    var hasHostedLayout = false
    /// 上次装进来的光标样式；nil = 还没装过。记在视图上而不是 Coordinator：外壳切换时视图复用、
    /// Coordinator 重建，记在 Coordinator 上会让每次重建都重装一遍、盖掉程序自己设的光标。
    var appliedCursor: TerminalCursorLook?

    override var canBecomeFirstResponder: Bool { controller?.canTakeKeyboard ?? false }

    // MARK: 不在屏上不画

    /// 隐藏标签的 `opacity(0)` 拦不住绘制（实测 alpha 0 和 `isHidden` 都照画）：后台标签里程序还在输出时，
    /// 每一帧都在主线程上画一张没人看的图。字节照常解析，露出来时补画一次。
    ///
    /// 两种「看不见」都算：所在格的后台标签 / Agent 模式（`isOffScreen`，容器同步），以及整个 App
    /// 退到了后台（`isAppInBackground`，控制器同步）。后者是并行执行用 `BGContinuedProcessingTask`
    /// 续命、或退后台后系统给的那几十秒：SSH 还连着、输出照样到，前台标签照旧每帧重绘，
    /// 画的东西谁也看不见。系统切后台时取快照发生在 `didEnterBackground` 之后，此前最后一帧已经画好，
    /// 快照不受影响；`willEnterForeground` 时补画一次，回来看到的就是最新内容。
    var isOffScreen = false {
        didSet { updateDrawingSuppression() }
    }
    var isAppInBackground = false {
        didSet { updateDrawingSuppression() }
    }
    private(set) var suppressesDrawing = false {
        didSet {
            guard suppressesDrawing != oldValue else { return }
            // 看不见时闪烁光标的动画也停掉（SwiftTerm 补丁 #19）：它是个重复动画，只要在跑，
            // Core Animation 就得一帧帧地出图。
            suspendsCaretAnimation = suppressesDrawing
            if !suppressesDrawing { super.setNeedsDisplay(bounds) }
        }
    }

    private func updateDrawingSuppression() {
        suppressesDrawing = isOffScreen || isAppInBackground
    }

    override func setNeedsDisplay() {
        if !suppressesDrawing { super.setNeedsDisplay() }
    }

    override func setNeedsDisplay(_ rect: CGRect) {
        if !suppressesDrawing { super.setNeedsDisplay(rect) }
    }

    // MARK: 输入法：默认英文，用户切了就记住

    /// 用户在这个终端里切到的输入法；nil = 还没切过，用英文。每个标签各记各的。
    private var chosenInputMode: UITextInputMode?
    private var observesInputMode = false

    /// 系统在终端成为第一响应者时按它挑键盘。命令行默认要英文；用户用地球键切走（中文写提交说明、
    /// 跟 Claude Code 说话）之后，回到这个终端还是用户选的那个。
    override var textInputMode: UITextInputMode? {
        chosenInputMode ?? Self.englishInputMode ?? super.textInputMode
    }

    private static var englishInputMode: UITextInputMode? {
        UITextInputMode.activeInputModes.first { $0.primaryLanguage?.hasPrefix("en") == true }
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { controller?.keyboardFocusChanged(true) }
        if became, !observesInputMode {
            observesInputMode = true
            NotificationCenter.default.addObserver(self, selector: #selector(inputModeDidChange),
                                                   name: UITextInputMode.currentInputModeDidChangeNotification,
                                                   object: nil)
        }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { controller?.keyboardFocusChanged(false) }
        return resigned
    }

    @objc private func inputModeDidChange() {
        // 只记自己是第一响应者时的切换：别的标签抢到键盘时系统把键盘换成英文，那不是用户在这里选的。
        guard isFirstResponder, let mode = super.textInputMode else { return }
        chosenInputMode = mode
    }

    // MARK: 组字：光标处显示正在拼的字（SwiftTerm 补丁 #8 的钩子）

    private lazy var markedLabel: UILabel = {
        let label = UILabel()
        label.isUserInteractionEnabled = false
        label.isHidden = true
        addSubview(label)
        return label
    }()

    override func textInputDidChange() {
        let marked = markedTextRange.flatMap { text(in: $0) } ?? ""
        guard !marked.isEmpty, let caret = textInputCaretFrame else {
            markedLabel.isHidden = true
            return
        }
        markedLabel.attributedText = NSAttributedString(string: marked, attributes: [
            .font: font,
            .foregroundColor: nativeForegroundColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ])
        markedLabel.backgroundColor = nativeBackgroundColor
        markedLabel.sizeToFit()
        var frame = markedLabel.frame
        frame.size.height = max(frame.height, caret.height)
        // 靠右放不下就往左挪，别画出屏。
        frame.origin = CGPoint(x: max(0, min(caret.minX, bounds.width - frame.width)), y: caret.minY)
        markedLabel.frame = frame
        markedLabel.isHidden = false
        bringSubviewToFront(markedLabel)
    }

    // MARK: 粘贴：剪贴板里只有图片时当贴图

    override func paste(_ sender: Any?) {
        let board = UIPasteboard.general
        if !board.hasStrings, board.hasImages, let controller, controller.acceptsImages {
            controller.sendImage { try await RemoteDesktopPasteSource.clipboardImage() }
            return
        }
        super.paste(sender)
    }
}

/// 把 SwiftTerm 的 iOS `TerminalView` 桥接进 SwiftUI。Coordinator 实现
/// `TerminalViewDelegate`，把键盘输入与尺寸变化转给 `MobileTerminalController`。
/// 配色随 app 外观（日 / 夜）自动取 VS Code Light / Dark（对齐 macOS `TerminalColorScheme`）。
struct SwiftTermView: UIViewRepresentable {
    let controller: MobileTerminalController
    var fontSize: CGFloat = 11
    /// 是否为当前激活视图（终端模式）。Agent 模式时终端被移出屏外，传 false → 主动 resign；
    /// 否则 SwiftTerm 的 TerminalView 会一直抢第一响应者，把终端键盘悬在 Agent 输入框上。
    var isActive: Bool = true
    /// 是否允许会话出现即自动弹键盘。连接中页期间传 false——否则键盘会盖住中转页、
    /// 并因软键盘安全区收缩把中转页内容顶上去（动画错乱）。中转页撤下后由终端屏重新聚焦。
    var autoFocus: Bool = true
    /// 这片终端在不在屏上（所在格的前台标签、终端模式）。不在屏上时不跟尺寸，见 `MTerminalContainerView`。
    var isOnScreen: Bool = true
    /// 用户点了终端（分屏时据此切聚焦格）。SwiftUI 手势拿不到 UIKit 视图上的触摸，
    /// 所以挂一个不吞触摸的 UITapGestureRecognizer。
    var onInteract: (() -> Void)? = nil
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.mTerminalHoldsFontSize) private var holdsFontSize
    /// 光标形状 / 闪烁：与 Mac 同步的两个偏好（设置 › 终端里改，默认见 `TerminalCursorPreference`）。
    @AppStorage(DefaultsKey.terminalCursorShape)
    private var cursorShapeRaw: String = TerminalCursorPreference.defaultShape.rawValue
    @AppStorage(DefaultsKey.terminalCursorBlink)
    private var cursorBlink: Bool = TerminalCursorPreference.defaultBlink

    private var cursorLook: TerminalCursorLook {
        TerminalCursorLook(shape: TerminalCursorPreference.shape(rawValue: cursorShapeRaw), blink: cursorBlink)
    }

    func makeUIView(context: Context) -> MTerminalContainerView {
        // 复用控制器已持有的终端视图：横屏翻 size class 会令外壳在 Tab/Split 间切换、
        // TerminalScreen 连带重建——复用同一视图可保活 SwiftTerm 的屏幕缓冲与回滚，
        // 既不空白也不断连。仅首次创建新视图。
        let view = controller.terminalView ?? MTerminalView(
            frame: .zero, font: UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular))
        (view as? MTerminalView)?.controller = controller
        // 位置与尺寸已由 SwiftUI 排好，终端（UIScrollView）不能再按安全区自己加一层内边距：
        // Duo 真机分屏时右格挨着状态栏，系统给它报了上 / 左安全区，内容被整体顶到右下、
        // 右边一截出屏（实机反馈；模拟器的状态栏区域与真机不同，复现不了）。
        view.contentInsetAdjustmentBehavior = .never
        // 把（可能是新建的）coordinator 接上：复用旧视图时旧 coordinator 已随旧表示层销毁。
        view.terminalDelegate = context.coordinator
        context.coordinator.onInteract = onInteract
        // 复用旧视图时先摘掉上一个表示层留下的识别器（它的 target 是已销毁的旧 coordinator）。
        view.gestureRecognizers?
            .filter { $0.name == Coordinator.interactGestureName }
            .forEach(view.removeGestureRecognizer)
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.interacted))
        tap.name = Coordinator.interactGestureName
        tap.cancelsTouchesInView = false
        tap.delegate = context.coordinator
        view.addGestureRecognizer(tap)
        // 普通键盘：用户能用地球键切到中文等输入法（`.asciiCapable` 只能在 ASCII 键盘间切）。
        // 「默认英文」由 `MTerminalView.textInputMode` 负责。联想 / 自动更正 / 智能标点已由
        // SwiftTerm 默认关闭（autocorrection 等均为 .no）。
        view.keyboardType = .default
        // 去掉 SwiftTerm 自带的键盘附加栏（esc/ctrl/tab/F1/方向键……），它和我们自绘的
        // `TerminalKeyBar` 重复堆两层。置 nil 后键盘上方只留 `TerminalKeyBar` 一层。
        view.inputAccessoryView = nil
        // 收起键盘后用户还在看这个终端，光标不该变成表示失焦的空心框。分屏的当前格由焦点框标出。
        view.caretViewTracksFocus = false
        applyColorsIfNeeded(to: view, coordinator: context.coordinator)
        // 新建视图时装一次；复用的视图样式没变就不装（见 `applyCursorIfNeeded`）。
        applyCursorIfNeeded(to: view)
        controller.attach(view)
        // 键盘默认展开：会话出现即聚焦，无需先点终端（仅激活态、非连接中页期间、已连上、用户没收起——
        // 失败重试成功后失败页换回本视图时走这里）。
        if isActive, autoFocus { DispatchQueue.main.async { controller.focusKeyboard() } }
        let container = MTerminalContainerView(terminalView: view, fontSize: fontSize)
        container.isOnScreen = isOnScreen
        return container
    }

    func updateUIView(_ container: MTerminalContainerView, context: Context) {
        let uiView = container.terminalView
        context.coordinator.onInteract = onInteract
        // 外观切换（日 / 夜）时重应用配色。只在日夜真的变了才装：父视图每次重算都会
        // 调到这里（拖分隔条 / 拖标签时每帧一次），而装一次配色会清掉 SwiftTerm 的属性
        // 与颜色缓存并整屏重绘——所有挂着的终端（含看不见的标签）都会跟着每帧重绘。
        applyColorsIfNeeded(to: uiView, coordinator: context.coordinator)
        // 设置里改了光标形状 / 闪烁（或从 Mac 同步过来）时重装。
        applyCursorIfNeeded(to: uiView)
        container.isOnScreen = isOnScreen
        // 字号随屏幕 / 视图宽度自适应：旋转、分屏时和新宽度一起提交，缓冲区只重排一次。
        // 拖分隔条时等松手再换，否则停顿一下就要重排一次。
        if !holdsFontSize { container.setFontSize(fontSize) }
        // Agent 模式（isActive=false）：主动收键盘，否则终端键盘盖住 Agent 输入框。
        if !isActive, uiView.isFirstResponder { _ = uiView.resignFirstResponder() }
    }

    static func dismantleUIView(_ container: MTerminalContainerView, coordinator: Coordinator) {
        container.cancelHold()
    }

    private func applyColorsIfNeeded(to view: SwiftTerm.TerminalView, coordinator: Coordinator) {
        let dark = colorScheme == .dark
        guard coordinator.appliedDark != dark else { return }
        coordinator.appliedDark = dark
        let scheme = MTerminalColors.resolve(dark: dark)
        TerminalAppearance.applyColors(to: view, scheme: scheme)
        // 光标颜色随配色切，形状不动（形状只在设置变了才装，见 applyCursorIfNeeded）。
        TerminalAppearance.applyCaretColors(to: view, scheme: scheme, shape: cursorLook.shape)
        // iOS 独有：UIScrollView 自己的底色（滚出内容区、橡皮筋回弹时露出来）也随终端底色。
        view.backgroundColor = scheme.backgroundColor
    }

    /// 光标形状 + 闪烁，只在和上次装的不同才装：装光标会盖掉程序自己设的（vim 插入模式的竖线），
    /// 并把它记成终端默认样式——程序发 `CSI 0 q` / reset 时回到用户选的样式，而不是 SwiftTerm 自带的闪烁块。
    /// 与 mac `TerminalTheme.applyLook` 同一取舍：用户改设置时接受盖掉程序当下自设的光标。
    private func applyCursorIfNeeded(to view: SwiftTerm.TerminalView) {
        let look = cursorLook
        let terminal = view as? MTerminalView
        if let terminal, terminal.appliedCursor == look { return }
        terminal?.appliedCursor = look
        TerminalAppearance.applyCursor(to: view, scheme: MTerminalColors.resolve(dark: colorScheme == .dark),
                                       shape: look.shape, blink: look.blink)
    }

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

    final class Coordinator: NSObject, TerminalViewDelegate, UIGestureRecognizerDelegate {
        static let interactGestureName = "uterm.interact"
        let controller: MobileTerminalController
        var onInteract: (() -> Void)?
        /// 上次装进视图的是不是暗色配色；nil = 还没装过。
        var appliedDark: Bool?
        init(controller: MobileTerminalController) { self.controller = controller }

        @objc func interacted() { onInteract?() }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
            controller.write(Data(data))
        }
        func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {
            controller.resize(cols: UInt16(clamping: newCols), rows: UInt16(clamping: newRows))
        }
        func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) {
            controller.receiveShellTitle(title)
        }
        func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}
        func scrolled(source: SwiftTerm.TerminalView, position: Double) {}
        func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {}
        func requestOpenLink(source: SwiftTerm.TerminalView, link: String, params: [String: String]) {
            if let url = URL(string: link) { UIApplication.shared.open(url) }
        }
    }
}
