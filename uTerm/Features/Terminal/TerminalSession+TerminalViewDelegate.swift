import SwiftUI
import SwiftTerm
import AppKit

// MARK: - TerminalViewDelegate

extension TerminalSession {
    // SwiftTerm 现在只是不上屏的影子（给远控快照与 holder 检查点用，下一步换成影子终端的二进制快照后整个删掉）：
    // 键盘输入、应答、尺寸、剪贴板都以 Ghostty 为准，它这边的回调一律不接。
    func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) { }

    /// uTerm 自己要发给程序的字节（OSC 7501 应答、贴图后的路径），以及 Ghostty 发出的键盘输入与应答。
    /// 进有序输入通道（`TerminalInputChannel`），按产生顺序到达后端。回放的是历史输出，里面的查询当年已经回答过了。
    func sendHostBytes(_ data: Data) {
        guard !isReplayingHeldOutput else { return }
        inputChannel.write(data)
    }

    func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) { }
    func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) { }
    func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) { }
    func scrolled(source: SwiftTerm.TerminalView, position: Double) { }
    func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) { }
    func clipboardCopy(source: SwiftTerm.TerminalView, content: Data) { }
    func bell(source: SwiftTerm.TerminalView) { }

    /// 过渡期：SwiftTerm 影子的尺寸跟着 Ghostty 的网格走。
    func resizeLegacyShadow(cols: Int, rows: Int) {
        let terminal = terminalView.getTerminal()
        if terminal.cols != cols || terminal.rows != rows { terminal.resize(cols: cols, rows: rows) }
    }
}
