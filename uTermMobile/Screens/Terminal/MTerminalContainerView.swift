import SwiftTerm
import UIKit

/// 终端视图的容器：SwiftUI 只改容器的尺寸，终端等尺寸和字号都停稳才跟上。
///
/// SwiftTerm 一见到新尺寸就重排缓冲区，全屏程序（vim、Claude Code）却要等 SIGWINCH 才知道，这段时间差里
/// 它照旧按旧尺寸增量绘制。尺寸变过去又变回来时 PTY 尺寸没变，连 SIGWINCH 都没有，屏幕就一直错位。
/// 停稳才提交之后，重排和 SIGWINCH 同时发生，键盘升降、切分屏途中的尺寸都不碰缓冲区。
final class MTerminalContainerView: UIView {
    /// 尺寸或字号停止变化多久后才提交给终端。连续变化期间不断顺延。
    static let settleDelay: Duration = .milliseconds(80)

    let terminalView: SwiftTerm.TerminalView
    private var fontSize: CGFloat
    private var held: Layout?
    private var settleTask: Task<Void, Never>?

    private struct Layout: Equatable {
        let size: CGSize
        let fontSize: CGFloat
    }

    init(terminalView: SwiftTerm.TerminalView, fontSize: CGFloat) {
        self.terminalView = terminalView
        self.fontSize = fontSize
        super.init(frame: .zero)
        clipsToBounds = true
        terminalView.translatesAutoresizingMaskIntoConstraints = true
        terminalView.autoresizingMask = []
        addSubview(terminalView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        syncTerminal(settled: false)
    }

    func setFontSize(_ size: CGFloat) {
        guard abs(fontSize - size) > 0.1 else { return }
        fontSize = size
        syncTerminal(settled: false)
    }

    func cancelHold() {
        settleTask?.cancel()
        settleTask = nil
        held = nil
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
        let target = Layout(size: bounds.size, fontSize: fontSize)
        let fontChanged = abs(terminalView.font.pointSize - fontSize) > 0.1
        let isFirstMount = (terminalView as? MTerminalView)?.hasHostedLayout == false
        if settled || isFirstMount || (!fontChanged && terminalView.frame.size == bounds.size) {
            cancelHold()
            (terminalView as? MTerminalView)?.hasHostedLayout = true
            commit(fontChanged: fontChanged)
            return
        }
        // 等待期间保持旧尺寸：比容器矮时贴顶，比容器高时贴底（键盘升起时提示符和光标留在屏上）。
        terminalView.frame.origin = CGPoint(x: 0, y: min(0, bounds.height - terminalView.frame.height))
        guard held != target else { return }
        held = target
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: Self.settleDelay)
            guard !Task.isCancelled else { return }
            self?.syncTerminal(settled: true)
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
