import AppKit
import SwiftTerm

// MARK: - 远控接管尺寸

extension TerminalSession {

    /// 远端接管尺寸的上限：远大于任何手机 / 平板能排下的行列，又不至于让缓冲区失控。
    static let maxRemoteGridCols = 1000
    static let maxRemoteGridRows = 500

    /// 远端设备接管尺寸：把终端钉成 `cols × rows`，远端 PTY 随之调整。
    ///
    /// 做法是把终端视图的尺寸钉成「行列数 × 字符格」：SwiftTerm 只在视图尺寸变化时重算行列数，
    /// 钉住之后用户拖窗口只改变外层容器，终端尺寸不受影响。视图尺寸一变，现有链路照常运转：
    /// `sizeChanged` → `backend.resize`（SIGWINCH）；镜像端则收到新尺寸下的快照。
    ///
    /// 字符格宽包外拿不到（`cellDimension` 与滚动条预留宽度都是 internal），所以先按估算设一次，
    /// 再看 SwiftTerm 实际算出的列数逐步逼近（`RemoteGridFit`）。设尺寸会同步触发重算；中间那几次尺寸
    /// 在同一轮主线程里，输入通道合并成最后一次才发给 PTY。
    func pinRemoteGrid(cols requestedCols: Int, rows requestedRows: Int, controller: String) {
        // 行列数来自手机：不设上限的话 65535×65535 会让 SwiftTerm 分配几十亿个格子，Mac 端卡死或被系统杀掉。
        let cols = min(requestedCols, Self.maxRemoteGridCols)
        let rows = min(requestedRows, Self.maxRemoteGridRows)
        guard cols > 0, rows > 0, let view = terminalView as? CopyableTerminalView else { return }
        remoteController = controller
        let terminal = view.getTerminal()
        let start = view.getOptimalFrameSize().size
        let cellWidth = start.width / CGFloat(max(1, terminal.cols))
        let cellHeight = start.height / CGFloat(max(1, terminal.rows))
        // +0.5：行列数是向下取整算出来的，留半点余量防浮点误差少算一行 / 一列。
        var width = RemoteGridFit(target: cols, cell: cellWidth)
        var height = RemoteGridFit(target: rows, cell: cellHeight)
        var size = NSSize(width: width.first, height: height.first)
        for _ in 0..<RemoteGridFit.maxSteps {
            view.setFrameSize(size)
            if terminal.cols == cols && terminal.rows == rows { break }
            size = NSSize(width: width.next(after: size.width, got: terminal.cols),
                          height: height.next(after: size.height, got: terminal.rows))
        }
        view.pinnedFrameSize = view.frame.size
        view.superview?.needsLayout = true
    }

    /// 解除接管：终端回到按窗格大小排布，远端 PTY 随之恢复。
    func unpinRemoteGrid() {
        guard let view = terminalView as? CopyableTerminalView else { return }
        remoteController = nil
        guard view.pinnedFrameSize != nil else { return }
        view.pinnedFrameSize = nil
        if let container = view.superview {
            container.needsLayout = true
            container.layoutSubtreeIfNeeded()
        }
        // 窗格此刻不在视图层级里（藏在别的标签后面）时，下次显示时容器布局会把尺寸还原。
    }

    /// 远端设备的键盘输入：原始字节原样写进后端。
    ///
    /// 与本地键盘（`send(source:data:)`）走同一条有序输入通道，两边的字节按到达顺序交错。
    func writeRemoteInput(_ data: Data) {
        inputChannel.write(data)
    }
}

/// 按实测行列数逼近视图尺寸（一个方向一份）。
///
/// 估算的格宽来自「整个视图宽 ÷ 列数」，里面摊着滚动条预留和边距，比真实格宽大一点。只按它补差额时，
/// 一步可能正好跨过目标列那一格宽的区间，在差一列和多一列之间来回跳，几步之后放弃——手机 62 列、
/// Mac 钉在 61 列，Claude Code 的输入框在手机上整个错位（真机回归）。所以一旦两边都见过（少了、多了），
/// 就在这两个尺寸之间二分：区间每步减半，几步之内落进那一格宽里。
nonisolated struct RemoteGridFit {
    static let maxSteps = 12

    let target: Int
    let cell: CGFloat
    /// 见过的「列数少于目标」里最大的尺寸、「多于目标」里最小的尺寸。
    private var below: CGFloat?
    private var above: CGFloat?

    init(target: Int, cell: CGFloat) {
        self.target = target
        self.cell = max(1, cell)
    }

    /// 第一次试的尺寸：按估算格宽对准目标那一格的中间，而不是贴着下沿。
    var first: CGFloat { cell * (CGFloat(target) + 0.5) }

    mutating func next(after size: CGFloat, got: Int) -> CGFloat {
        if got == target { return size }
        if got < target { below = max(below ?? size, size) } else { above = min(above ?? size, size) }
        if let below, let above { return (below + above) / 2 }
        return size + CGFloat(target - got) * cell
    }
}
