import UIKit

/// 终端视图的容器：SwiftUI 只改容器的尺寸，终端等尺寸和字号都停稳才跟上。
///
/// 终端一见到新尺寸就重排网格并给远端发 SIGWINCH，全屏程序（vim、Claude Code）收到就整屏重画。键盘升降、转屏、
/// 切分屏途中会连着经过一串中间尺寸，每个都重排 + 重画一遍既费又闪；尺寸变过去又变回来时还会白白折腾两次。
/// 停稳才提交之后，一次变化只重排一次、只发一次 SIGWINCH。
final class MTerminalContainerView: UIView {
    /// 尺寸或字号停止变化多久后才提交给终端。连续变化期间不断顺延（判定在共享的 `TerminalResizeSettler`）。
    static let settleDelay: Duration = TerminalResizeSettler.settleDelay

    let terminal: GhosttyTerminalBridge
    var terminalView: MGhosttyTerminalView { terminal.view }
    private var fontSize: CGFloat
    /// 「停稳再提交」的判定与顺延计时（与 mac `TerminalContainerView` 共用）。
    private let settler = TerminalResizeSettler()
    private var commitsOnNextLayout = false

    /// 这个终端在不在屏上。不在屏上时不跟尺寸、不画（隔一阵还会放掉 surface，见 `GhosttyTerminalBridge.setOnScreen`），
    /// 转屏才不会让每个隐藏标签都重排一次、再让里面的程序重发一遍内容。切回来时立刻提交（和 Mac 一样：隐藏的终端
    /// 露出来才改尺寸）。
    var isOnScreen: Bool {
        didSet {
            guard isOnScreen != oldValue else { return }
            // 外壳切换时新容器接走了同一个终端视图：旧容器之后的状态变化（它最后一次刷新常常是「不在屏上」）
            // 不能再写进视图，否则视图停画、画面永远停在那一刻。和 `syncTerminal` 的守卫同一条规则。
            guard terminalView.superview === self else { return }
            if isOnScreen {
                // 在尺寸提交之前把旧帧盖上：提交会改视图（和里面的层）的 frame，晚了盖子量到的就是新 frame、旧帧被裁 / 挪位。
                terminal.prepareSwitchBack()
                // 先把攒着的尺寸提交了再让画面回来：surface 放掉过的话，直接按新尺寸重建，不用先建再改。
                commitsOnNextLayout = true
                setNeedsLayout()
                layoutIfNeeded()
                terminal.setOnScreen(true)
            } else {
                cancelHold()
                terminal.setOnScreen(false)
            }
        }
    }

    init(terminal: GhosttyTerminalBridge, fontSize: CGFloat, isOnScreen: Bool = true) {
        self.terminal = terminal
        self.fontSize = fontSize
        self.isOnScreen = isOnScreen
        super.init(frame: .zero)
        // 盖子（`GhosttySwitchBackCover`）撤之前问：这个容器还有没落地的布局吗。要在下面 `setOnScreen` 建盖子之前接上。
        terminal.geometryPending = { [weak self] in self?.hasPendingGeometry ?? false }
        clipsToBounds = true
        let view = terminal.view
        view.translatesAutoresizingMaskIntoConstraints = true
        view.autoresizingMask = []
        addSubview(view)
        // 外壳切换时新容器接走旧视图：以新容器的状态为准，别沿用上一个容器留下的「不在屏上」。
        terminal.setOnScreen(isOnScreen)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let settled = commitsOnNextLayout
        commitsOnNextLayout = false
        syncTerminal(settled: settled)
    }

    func setFontSize(_ size: CGFloat) {
        guard abs(fontSize - size) > 0.1 else { return }
        fontSize = size
        syncTerminal(settled: false)
    }

    /// 终端还没跟上容器：在等停稳（`hold`），或视图的尺寸 / 字号和容器此刻的目标不一样，或容器还没排过版。
    /// 不在屏上不跟尺寸，不算没落地。
    var hasPendingGeometry: Bool {
        guard isOnScreen, terminalView.superview === self else { return false }
        if bounds.width <= 0 || bounds.height <= 0 { return true }
        if settler.held != nil { return true }
        let current = TerminalResizeSettler.Target(size: terminalView.frame.size, fontSize: terminalView.terminalFontSize)
        return !current.matches(TerminalResizeSettler.Target(size: bounds.size, fontSize: fontSize))
    }

    func cancelHold() {
        settler.cancel()
    }

    private func syncTerminal(settled: Bool) {
        let terminalView = terminalView
        // 外壳切换时新容器会接走同一个终端视图，旧容器不再摆放它。
        guard terminalView.superview === self else {
            cancelHold()
            return
        }
        // 还没排好或被收起时没有可用空间：保持原有行列数，等它再露出来。
        guard bounds.width > 0, bounds.height > 0 else {
            cancelHold()
            return
        }
        let isFirstMount = !terminalView.hasHostedLayout
        // 不在屏上不跟尺寸（首挂除外：总得先按真实尺寸排一次版）。
        let tracks = isOnScreen || isFirstMount
        let decision = settler.decide(
            target: tracks ? TerminalResizeSettler.Target(size: bounds.size, fontSize: fontSize) : nil,
            current: TerminalResizeSettler.Target(size: terminalView.frame.size,
                                                  fontSize: terminalView.terminalFontSize),
            isFirstMount: isFirstMount,
            settled: settled,
            onSettled: { [weak self] in self?.syncTerminal(settled: true) })
        switch decision {
        case .cancel:
            return
        case .commit:
            terminalView.hasHostedLayout = true
            commit()
        case .hold:
            // 等待期间保持旧尺寸：比容器矮时留在按行填满的下移位置（别先跳到 0 再回来），比容器高时往上挪到提示符和光标
            // 留在屏上为止（`heldOriginY`）。
            // 比容器矮（键盘收起）时：提交后内容会贴底的话（`growsFromScrollback`）现在就贴底，跟着按键条往下走，
            // 空出来的在上面、提交后由回滚补上；否则留在顶上。
            let room = bounds.height - terminalView.frame.height
            let y: CGFloat = if room < 0 {
                heldOriginY(room: room)
            } else if terminal.growsFromScrollback {
                room
            } else {
                terminal.link.rowFillOffset
            }
            terminalView.frame.origin = CGPoint(x: 0, y: y)
        }
    }

    /// 终端比容器高（键盘升起）、还在等停稳时放在哪：往上挪到有内容的最后一行刚好留在屏上，最多贴底。
    /// 内容占满一屏时等于贴底；只占上面几行（刚登录的 shell）时原地不动——一律贴底的话那几行会被推出屏幕，
    /// 等提交才回来，中间整片空白。提交之后终端也是这么收行的（先裁光标下面的空行），所以前后画面对得上。
    private func heldOriginY(room: CGFloat) -> CGFloat {
        let rows = terminal.occupiedRows
        let used = terminalView.frame.height * CGFloat(rows.used) / CGFloat(rows.total)
        return max(room, min(terminal.link.rowFillOffset, bounds.height - used))
    }

    /// 尺寸和字号一起提交：GhosttyKit 的 IO 线程把挨着的两次 resize 合成一次（25 ms 窗口），远端只收到一次 SIGWINCH。
    /// 接着按行填满（`TerminalRowFill`，两端共用）：按新尺寸、新字号重算行高（同一轮里推给 surface，也落在那 25 ms 里），
    /// 拉不完的零头上下均分——视图往下挪上半份，尺寸不变（网格不变），露在容器底边外的下半份被裁掉。
    ///
    /// 等停稳期间视图按旧尺寸挪着放（`hold`），提交时挪回来；引擎交出新尺寸的帧之前，层上还是旧帧，会跟着视图挪、按顶边对齐露出来
    ///（键盘升起时按键条上方闪一下旧内容的顶部）。所以挪位置之前先把旧帧盖上，提交后让它留在屏上原处，等新帧就绪再撤。
    private func commit() {
        let terminalView = terminalView
        let before = terminalView.frame
        let moves = isOnScreen && before.height > 0 && before.size != bounds.size
        if moves { terminal.coverBeforeMoving() }
        terminalView.frame = bounds
        terminalView.setTerminalFontSize(fontSize)
        terminalView.layoutIfNeeded()
        terminal.link.refitRowFill()
        terminalView.frame.origin.y = terminal.link.rowFillOffset
        if moves { terminal.keepCoverOnScreen(viewMovedBy: terminalView.frame.minY - before.minY) }
        // 不在屏上的终端不建 surface，没有网格可报：先估一个给远端（见 `estimateGridIfNeverSized`）。
        if !isOnScreen { terminal.estimateGridIfNeverSized(for: bounds.size) }
    }
}
