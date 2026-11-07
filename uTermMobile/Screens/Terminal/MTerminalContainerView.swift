import SwiftTerm
import UIKit

/// 终端视图的容器：SwiftUI 只改容器的尺寸，终端等尺寸和字号都停稳才跟上。
///
/// SwiftTerm 一见到新尺寸就重排缓冲区，全屏程序（vim、Claude Code）却要等 SIGWINCH 才知道，这段时间差里
/// 它照旧按旧尺寸增量绘制。尺寸变过去又变回来时 PTY 尺寸没变，连 SIGWINCH 都没有，屏幕就一直错位。
/// 停稳才提交之后，重排和 SIGWINCH 同时发生，键盘升降、切分屏途中的尺寸都不碰缓冲区。
final class MTerminalContainerView: UIView {
    /// 尺寸或字号停止变化多久后才提交给终端。连续变化期间不断顺延（判定在共享的 `TerminalResizeSettler`）。
    static let settleDelay: Duration = TerminalResizeSettler.settleDelay

    let terminalView: SwiftTerm.TerminalView
    private var fontSize: CGFloat
    /// 「停稳再提交」的判定与顺延计时（与 mac `TerminalContainerView` 共用）。
    private let settler = TerminalResizeSettler()
    private var commitsOnNextLayout = false

    /// 这个终端在不在屏上。不在屏上时不跟尺寸，转屏才不会让每个隐藏标签都重排一次、再让里面的程序
    /// 重发一遍内容。切回来时立刻提交（和 Mac 一样：隐藏的终端露出来才改尺寸）。
    var isOnScreen = true {
        didSet {
            guard isOnScreen != oldValue else { return }
            (terminalView as? MTerminalView)?.isOffScreen = !isOnScreen
            if isOnScreen {
                commitsOnNextLayout = true
                setNeedsLayout()
            } else {
                cancelHold()
            }
        }
    }

    init(terminalView: SwiftTerm.TerminalView, fontSize: CGFloat) {
        self.terminalView = terminalView
        self.fontSize = fontSize
        super.init(frame: .zero)
        clipsToBounds = true
        terminalView.translatesAutoresizingMaskIntoConstraints = true
        terminalView.autoresizingMask = []
        addSubview(terminalView)
        // 外壳切换时新容器接走旧视图：以新容器的状态为准，别沿用上一个容器留下的「不在屏上」。
        (terminalView as? MTerminalView)?.isOffScreen = !isOnScreen
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

    func cancelHold() {
        settler.cancel()
    }

    private func syncTerminal(settled: Bool) {
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
        let fontChanged = abs(terminalView.font.pointSize - fontSize) > 0.1
        let isFirstMount = (terminalView as? MTerminalView)?.hasHostedLayout == false
        // 不在屏上不跟尺寸（首挂除外：总得先按真实尺寸排一次版）。
        let tracks = isOnScreen || isFirstMount
        let decision = settler.decide(
            target: tracks ? TerminalResizeSettler.Target(size: bounds.size, fontSize: fontSize) : nil,
            current: TerminalResizeSettler.Target(size: terminalView.frame.size,
                                                  fontSize: terminalView.font.pointSize),
            isFirstMount: isFirstMount,
            settled: settled,
            onSettled: { [weak self] in self?.syncTerminal(settled: true) })
        switch decision {
        case .cancel:
            return
        case .commit:
            (terminalView as? MTerminalView)?.hasHostedLayout = true
            commit(fontChanged: fontChanged)
        case .hold:
            // 等待期间保持旧尺寸：比容器矮时贴顶，比容器高时贴底（键盘升起时提示符和光标留在屏上）。
            terminalView.frame.origin = CGPoint(x: 0, y: min(0, bounds.height - terminalView.frame.height))
        }
    }

    /// 先改尺寸再换字号：换字号时按新尺寸算行列数，缓冲区只重排一次。
    private func commit(fontChanged: Bool) {
        terminalView.frame = bounds
        if fontChanged {
            terminalView.font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        }
        terminalView.layoutIfNeeded()
    }
}
