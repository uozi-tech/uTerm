import AppKit
import SwiftTerm

// MARK: - 远控接管尺寸

extension TerminalSession {

    /// 远端设备接管尺寸：把终端钉成 `cols × rows`，远端 PTY 随之调整。
    ///
    /// 做法是把终端视图的尺寸钉成「行列数 × 字符格」：SwiftTerm 只在视图尺寸变化时重算行列数，
    /// 钉住之后用户拖窗口只改变外层容器，终端尺寸不受影响。视图尺寸一变，现有链路照常运转：
    /// `sizeChanged` → `backend.resize`（SIGWINCH）；镜像端则收到新尺寸下的快照。
    ///
    /// 字符格宽包外拿不到（`cellDimension` 与滚动条预留宽度都是 internal），所以先按估算设一次，
    /// 再看 SwiftTerm 实际算出的列数，差几列补几列。设尺寸会同步触发重算，两三步就收敛。
    func pinRemoteGrid(cols: Int, rows: Int, controller: String) {
        guard cols > 0, rows > 0, let view = terminalView as? CopyableTerminalView else { return }
        remoteController = controller
        let terminal = view.getTerminal()
        let start = view.getOptimalFrameSize().size
        let cellWidth = start.width / CGFloat(max(1, terminal.cols))
        let cellHeight = start.height / CGFloat(max(1, terminal.rows))
        // +0.5：行列数是向下取整算出来的，留半点余量防浮点误差少算一行 / 一列。
        var size = NSSize(width: cellWidth * CGFloat(cols) + 0.5, height: cellHeight * CGFloat(rows) + 0.5)
        for _ in 0..<5 {
            view.setFrameSize(size)
            if terminal.cols == cols && terminal.rows == rows { break }
            size.width += CGFloat(cols - terminal.cols) * cellWidth
            size.height += CGFloat(rows - terminal.rows) * cellHeight
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
    /// 与本地键盘（`send(source:data:)`）走同一个 `backend.write`，顺序同样由
    /// `SSHConnection` 内部的 FIFO 写队列保证。
    func writeRemoteInput(_ data: Data) {
        guard let backend else { return }
        Task { await backend.write(data) }
    }
}
