import SwiftUI
import SwiftTerm
import AppKit

// MARK: - TerminalViewDelegate

extension TerminalSession {
    func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
        // 交互式终端：键盘 / 粘贴字节进有序输入通道（`TerminalInputChannel`），按产生顺序到达后端。
        // 回放的是历史输出，里面的查询当年已经回答过了。
        // Ghostty 渲染时 SwiftTerm 是影子：键盘输入只从 Ghostty 来，应答也以 Ghostty 的为准。
        guard ghostty == nil else { return }
        sendHostBytes(Data(data))
    }

    /// uTerm 自己要发给程序的字节（OSC 7501 应答、贴图后的路径），以及 Ghostty 发出的键盘输入与应答。
    func sendHostBytes(_ data: Data) {
        guard !isReplayingHeldOutput else { return }
        inputChannel.write(data)
    }

    func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {
        // Ghostty 渲染时尺寸以 Ghostty 的网格为准（`ghosttyGridDidChange`）。
        guard ghostty == nil else { return }
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
