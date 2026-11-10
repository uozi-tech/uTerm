import AppKit
import UniformTypeIdentifiers

extension TerminalImage {
    /// 剪贴板里只有图片时取出来。有文字时返回 nil：Finder 复制文件、Word 复制内容都同时带
    /// 文字和图片，这时用户要的是文字。
    static func fromPasteboard(_ pasteboard: NSPasteboard) -> TerminalImage? {
        guard pasteboard.string(forType: .string) == nil else { return nil }
        if let data = pasteboard.data(forType: .png) {
            return TerminalImage(format: .png, data: data)
        }
        if let data = pasteboard.data(forType: NSPasteboard.PasteboardType(UTType.jpeg.identifier)) {
            return TerminalImage(format: .jpeg, data: data)
        }
        guard let tiff = pasteboard.data(forType: .tiff),
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
            return nil
        }
        return TerminalImage(format: .png, data: png)
    }
}

extension TerminalSession {

    /// 有 Agent 正在这条会话里报告状态（包括空闲）。
    /// 远控镜像不自己解析状态，看那台 Mac 推来的。
    private var hasRunningAgent: Bool {
        if let remote = backend as? RemoteTerminalBackend {
            return remote.client.programReport(for: remote.sessionID) != nil
        }
        return programStatusTracker.hasRecords
    }

    /// ⌘V 粘贴只有图片的剪贴板。返回 false = 没接管，走普通粘贴。
    ///
    /// 本机 shell 没有 Agent 时不接管：贴图靠替用户按 Ctrl+V，而 Ctrl+V 在 shell 里是转义输入。
    /// 接回的会话没拿到程序状态时（`programStatusUnknown`）先把按键收下，再问前台是谁：是 shell 以外的程序就当它是
    /// 重启前就在跑的 Agent。剪贴板里只有图片，普通粘贴本来就贴不出东西，收下按键不会吃掉什么。
    func pasteImage(_ image: TerminalImage) -> Bool {
        guard let receiver = backend as? any TerminalImageReceiving else { return false }
        if !receiver.programsCanReadMacClipboard || hasRunningAgent {
            deliver(image, to: receiver)
            return true
        }
        guard programStatusUnknown else { return false }
        let generation = feedGeneration
        Task { [weak self] in
            let activity = await receiver.foregroundActivity()
            guard let self, self.feedGeneration == generation, self.programStatusUnknown else { return }
            switch activity {
            case .running: self.deliver(image, to: receiver)
            // 回到了 shell：重启前跑着的那个程序已经结束，之后的程序要报状态才算 Agent。
            case .idle: self.programStatusUnknown = false
            case .unknown: break
            }
        }
        return true
    }

    /// Ctrl+V 粘贴只有图片的剪贴板。返回 false = 按键照常发给程序。
    ///
    /// Claude Code、Codex 用 Ctrl+V 贴图，但它们在 SSH 那头读不到 Mac 的剪贴板，这里替它们传。
    /// 只在有 Agent 时接管：Ctrl+V 在 vim 和 shell 里有自己的含义。本机 shell 的程序能自己
    /// 读剪贴板，不用管。
    func handleControlVImage(_ image: TerminalImage) -> Bool {
        guard hasRunningAgent,
              let receiver = backend as? any TerminalImageReceiving,
              !receiver.programsCanReadMacClipboard else { return false }
        deliver(image, to: receiver)
        return true
    }

    private func deliver(_ image: TerminalImage, to receiver: any TerminalImageReceiving) {
        Task { [weak self] in
            do {
                try await TerminalPaste.deliver(image: image, to: receiver) { self?.pasteText($0) }
            } catch {
                // 用户正等着图片出现，失败必须看得见；不走「是否在看」的判断。
                self?.attentionSink?(TerminalAttention(title: String(localized: "图片发送失败"),
                                                       body: error.localizedDescription))
            }
        }
    }

    /// 像系统粘贴一样送文字。Agent 靠括号粘贴标记认出这是粘贴，才把图片路径当附件。
    private func pasteText(_ text: String) {
        let data = TerminalPaste.wrap(text, bracketed: shadow.bracketedPasteMode)
        sendHostBytes(Data(data))
    }
}
