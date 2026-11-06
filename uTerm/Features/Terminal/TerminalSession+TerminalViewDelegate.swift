import SwiftUI
import SwiftTerm
import AppKit

// MARK: - TerminalViewDelegate

extension TerminalSession {
    func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
        // 交互式终端：键盘 / 粘贴字节进有序输入通道（`TerminalInputChannel`），按产生顺序到达后端。
        // 回放的是历史输出，里面的查询当年已经回答过了。
        guard !isReplayingHeldOutput else { return }
        inputChannel.write(Data(data))
    }

    func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {
        // 去重与同一轮内的合并在通道里（`reportSize`）。
        inputChannel.reportSize(cols: UInt16(clamping: newCols), rows: UInt16(clamping: newRows))
        // 终端刚按新尺寸重排过：镜像端改发一份新尺寸下的快照，不去追字节级的时序。
        mirrorTap.invalidateAll()
        heldCheckpoints?.noteScreenChanged()
    }

    func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) {
        receiveShellTitle(title)
    }
    func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) { }
    func scrolled(source: SwiftTerm.TerminalView, position: Double) { }
    func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) { }

    func clipboardCopy(source: SwiftTerm.TerminalView, content: Data) {
        guard !isReplayingHeldOutput, let string = String(data: content, encoding: .utf8) else { return }
        let pasteboard = (source as? CopyableTerminalView)?.pasteboard ?? .general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }
}
