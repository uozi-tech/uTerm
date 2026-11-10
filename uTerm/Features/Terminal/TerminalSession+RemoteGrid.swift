import AppKit

// MARK: - 远控接管尺寸

extension TerminalSession {

    /// 远端接管尺寸的上限：远大于任何手机 / 平板能排下的行列，又不至于让缓冲区失控。
    static let maxRemoteGridCols = 1000
    static let maxRemoteGridRows = 500

    /// 远端设备接管尺寸：把终端钉成 `cols × rows`，远端 PTY 随之调整。
    ///
    /// 做法是把 Ghostty 视图的尺寸钉成「行列数 × 格子像素」（`GhosttyTerminalBridge.pinGrid`）：网格只跟视图尺寸走，
    /// 钉住之后用户拖窗口只改变外层容器，终端尺寸不受影响。视图尺寸一变，现有链路照常运转：Ghostty 报来新网格 →
    /// `ghosttyGridDidChange` → `backend.resize`（SIGWINCH）；镜像端则收到新尺寸下的快照。
    func pinRemoteGrid(cols requestedCols: Int, rows requestedRows: Int, controller: String) {
        // 行列数来自手机：不设上限的话 65535×65535 会让终端分配几十亿个格子，Mac 端卡死或被系统杀掉。
        let cols = min(requestedCols, Self.maxRemoteGridCols)
        let rows = min(requestedRows, Self.maxRemoteGridRows)
        guard cols > 0, rows > 0 else { return }
        remoteController = controller
        ghostty.pinGrid(cols: cols, rows: rows)
    }

    /// 钉住期间来了新输出：光标换了行就让容器重新摆一次（比窗格高的终端跟着光标走）。每批输出查一次，只比一个整数。
    func repositionPinnedGridIfCursorMoved() {
        ghostty.repositionPinnedGridIfCursorMoved()
    }

    /// 解除接管：终端回到按窗格大小排布，远端 PTY 随之恢复。
    /// 窗格此刻不在视图层级里（藏在别的标签后面）时，下次显示时容器布局会把尺寸还原。
    func unpinRemoteGrid() {
        remoteController = nil
        ghostty.unpinGrid()
    }

    /// 远端设备的键盘输入：原始字节原样写进后端。
    ///
    /// 与本地键盘（`sendHostBytes`）走同一条有序输入通道，两边的字节按到达顺序交错。
    func writeRemoteInput(_ data: Data) {
        inputChannel.write(data)
    }
}
